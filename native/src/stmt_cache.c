/// stmt_cache.c — Per-connection LRU of prepared statements (ABI MINOR 7).
/// See stmt_cache.h for the contract. Worker-thread only: no locking.

#include "stmt_cache.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PENDING_MIN_CAP 16

// FNV-1a, 64 bits, over the SQL bytes and then the type OIDs.
static uint64_t key_hash(const char* sql, int32_t n_params,
                         const int32_t* types) {
    uint64_t h = 1469598103934665603ULL;
    for (const unsigned char* p = (const unsigned char*)sql; *p; p++) {
        h ^= *p;
        h *= 1099511628211ULL;
    }
    h ^= (uint64_t)(uint32_t)n_params;
    h *= 1099511628211ULL;
    if (types != NULL) {
        const unsigned char* b = (const unsigned char*)types;
        size_t len = (size_t)n_params * sizeof(int32_t);
        for (size_t i = 0; i < len; i++) {
            h ^= b[i];
            h *= 1099511628211ULL;
        }
    }
    return h;
}

// Types compare as "all zero" when the caller passed NULL.
static int types_equal(const int32_t* a, const int32_t* b, int32_t n) {
    for (int32_t i = 0; i < n; i++) {
        int32_t x = (a != NULL) ? a[i] : 0;
        int32_t y = (b != NULL) ? b[i] : 0;
        if (x != y) return 0;
    }
    return 1;
}

static void entry_free(stmt_entry_t* e) {
    free(e->sql);
    free(e->types);
    free(e);
}

static void list_unlink(stmt_cache_t* c, stmt_entry_t* e) {
    if (e->prev) e->prev->next = e->next; else c->head = e->next;
    if (e->next) e->next->prev = e->prev; else c->tail = e->prev;
    e->prev = e->next = NULL;
}

static void list_push_front(stmt_cache_t* c, stmt_entry_t* e) {
    e->prev = NULL;
    e->next = c->head;
    if (c->head) c->head->prev = e; else c->tail = e;
    c->head = e;
}

static void bucket_unlink(stmt_cache_t* c, stmt_entry_t* e) {
    if (c->n_buckets == 0) return;
    stmt_entry_t** pp = &c->buckets[e->hash & (uint64_t)(c->n_buckets - 1)];
    while (*pp != NULL && *pp != e) pp = &(*pp)->hnext;
    if (*pp == e) *pp = e->hnext;
    e->hnext = NULL;
}

static void bucket_insert(stmt_cache_t* c, stmt_entry_t* e) {
    stmt_entry_t** b = &c->buckets[e->hash & (uint64_t)(c->n_buckets - 1)];
    e->hnext = *b;
    *b = e;
}

static int32_t pending_cap_for(int32_t capacity) {
    int64_t want = (int64_t)capacity * 2;
    if (want < PENDING_MIN_CAP) want = PENDING_MIN_CAP;
    if (want > INT32_MAX) want = INT32_MAX;
    return (int32_t)want;
}

// Resizes the pending queue, keeping the newest names when shrinking.
// On allocation failure the old queue stays.
static void pending_resize(stmt_cache_t* c, int32_t new_cap) {
    if (new_cap == c->pending_cap) return;
    char (*q)[STMT_NAME_LEN] =
        (char (*)[STMT_NAME_LEN])malloc((size_t)new_cap * STMT_NAME_LEN);
    if (q == NULL) return;
    int32_t keep = c->n_pending < new_cap ? c->n_pending : new_cap;
    int32_t from = c->n_pending - keep;
    if (keep > 0) {
        memcpy(q, c->pending[from], (size_t)keep * STMT_NAME_LEN);
    }
    free(c->pending);
    c->pending = q;
    c->pending_cap = new_cap;
    c->n_pending = keep;
}

void stmt_cache_init(stmt_cache_t* c) {
    memset(c, 0, sizeof(*c));
}

static void drop_entries(stmt_cache_t* c, int queue_names) {
    stmt_entry_t* e = c->head;
    while (e != NULL) {
        stmt_entry_t* next = e->next;
        if (queue_names) stmt_cache_queue_close(c, e->name);
        entry_free(e);
        e = next;
    }
    c->head = c->tail = NULL;
    c->count = 0;
    if (c->buckets != NULL) {
        memset(c->buckets, 0, (size_t)c->n_buckets * sizeof(stmt_entry_t*));
    }
}

void stmt_cache_free(stmt_cache_t* c) {
    drop_entries(c, 0);
    free(c->buckets);
    free(c->pending);
    uint64_t next_id = c->next_id;
    stmt_cache_init(c);
    c->next_id = next_id;
}

void stmt_cache_clear(stmt_cache_t* c) {
    drop_entries(c, 0);
    c->n_pending = 0;
}

int stmt_cache_set_capacity(stmt_cache_t* c, int32_t capacity) {
    if (capacity < 0) capacity = 0;
    if (capacity == c->capacity) return 1;

    while (c->count > capacity) {
        stmt_entry_t* victim = c->tail;
        list_unlink(c, victim);
        bucket_unlink(c, victim);
        stmt_cache_queue_close(c, victim->name);
        entry_free(victim);
        c->count--;
    }

    if (capacity == 0) {
        free(c->buckets);
        c->buckets = NULL;
        c->n_buckets = 0;
        c->capacity = 0;
        return 1;
    }

    int64_t nb = 1;
    while (nb < (int64_t)capacity * 2) nb <<= 1;
    if (nb > INT32_MAX) nb = (int64_t)1 << 30;
    stmt_entry_t** buckets =
        (stmt_entry_t**)calloc((size_t)nb, sizeof(stmt_entry_t*));
    if (buckets == NULL) {
        drop_entries(c, 1);
        free(c->buckets);
        c->buckets = NULL;
        c->n_buckets = 0;
        c->capacity = 0;
        return 0;
    }
    free(c->buckets);
    c->buckets = buckets;
    c->n_buckets = (int32_t)nb;
    for (stmt_entry_t* e = c->head; e != NULL; e = e->next) {
        e->hnext = NULL;
        bucket_insert(c, e);
    }
    c->capacity = capacity;
    pending_resize(c, pending_cap_for(capacity));
    return 1;
}

stmt_entry_t* stmt_cache_lookup(stmt_cache_t* c, const char* sql,
                                int32_t n_params, const int32_t* types) {
    if (c->capacity == 0 || c->count == 0) return NULL;
    uint64_t h = key_hash(sql, n_params, types);
    stmt_entry_t* e = c->buckets[h & (uint64_t)(c->n_buckets - 1)];
    for (; e != NULL; e = e->hnext) {
        if (e->hash == h && e->n_params == n_params &&
            types_equal(e->types, types, n_params) &&
            strcmp(e->sql, sql) == 0) {
            if (c->head != e) {
                list_unlink(c, e);
                list_push_front(c, e);
            }
            return e;
        }
    }
    return NULL;
}

void stmt_cache_next_name(stmt_cache_t* c, char out[STMT_NAME_LEN]) {
    snprintf(out, STMT_NAME_LEN, "_ss%llu",
             (unsigned long long)c->next_id++);
}

int stmt_cache_insert(stmt_cache_t* c, const char* sql, int32_t n_params,
                      const int32_t* types, const char* name) {
    if (c->capacity == 0) {
        stmt_cache_queue_close(c, name);
        return 0;
    }
    stmt_entry_t* e = (stmt_entry_t*)calloc(1, sizeof(stmt_entry_t));
    size_t sql_len = strlen(sql) + 1;
    if (e != NULL) e->sql = (char*)malloc(sql_len);
    if (e != NULL && n_params > 0) {
        e->types = (int32_t*)calloc((size_t)n_params, sizeof(int32_t));
    }
    if (e == NULL || e->sql == NULL || (n_params > 0 && e->types == NULL)) {
        if (e != NULL) entry_free(e);
        stmt_cache_queue_close(c, name);
        return 0;
    }
    memcpy(e->sql, sql, sql_len);
    if (n_params > 0 && types != NULL) {
        memcpy(e->types, types, (size_t)n_params * sizeof(int32_t));
    }
    e->n_params = n_params;
    e->hash = key_hash(sql, n_params, types);
    snprintf(e->name, STMT_NAME_LEN, "%s", name);

    if (c->count >= c->capacity) {
        stmt_entry_t* victim = c->tail;
        list_unlink(c, victim);
        bucket_unlink(c, victim);
        stmt_cache_queue_close(c, victim->name);
        entry_free(victim);
        c->count--;
    }
    list_push_front(c, e);
    bucket_insert(c, e);
    c->count++;
    return 1;
}

void stmt_cache_remove(stmt_cache_t* c, stmt_entry_t* e, int queue_close) {
    list_unlink(c, e);
    bucket_unlink(c, e);
    if (queue_close) stmt_cache_queue_close(c, e->name);
    entry_free(e);
    c->count--;
}

void stmt_cache_queue_close(stmt_cache_t* c, const char* name) {
    if (c->pending_cap == 0) {
        pending_resize(c, pending_cap_for(c->capacity));
        if (c->pending_cap == 0) return;  // OOM: the statement is orphaned
    }
    if (c->n_pending == c->pending_cap) {
        memmove(c->pending[0], c->pending[1],
                (size_t)(c->n_pending - 1) * STMT_NAME_LEN);
        c->n_pending--;
    }
    snprintf(c->pending[c->n_pending], STMT_NAME_LEN, "%s", name);
    c->n_pending++;
}

void stmt_cache_pending_clear(stmt_cache_t* c) {
    c->n_pending = 0;
}

int stmt_cache_contains(const stmt_cache_t* c, const stmt_entry_t* e) {
    for (const stmt_entry_t* x = c->head; x != NULL; x = x->next) {
        if (x == e) return 1;
    }
    return 0;
}
