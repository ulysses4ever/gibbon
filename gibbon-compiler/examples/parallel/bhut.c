#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>
#include <alloca.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h> // For va_start etc
#include <errno.h>
#include <utlist.h>
#include <uthash.h>
#include <utarray.h>
#ifdef _POINTER
#include <gc.h>
#endif
#ifdef _PARALLEL
#include <cilk/cilk.h>
#include <cilk/reducer.h>
#include <cilk/cilk_api.h>
#endif

#define KB 1000lu
#define MB (KB * 1000lu)
#define GB (MB * 1000lu)

// Initial size of BigInfinite buffers
static long long global_init_biginf_buf_size = (1 * GB);

// Initial size of Infinite buffers
static long long global_init_inf_buf_size = 64 * KB;

// Maximum size of a chunk, see GitHub #110.
long long global_inf_buf_max_chunk_size = 1 * GB;

static long long global_size_param = 1;
static long long global_iters_param = 1;

static char* global_benchfile_param = NULL;
static char* global_arrayfile_param = NULL;

// Sequential for now:
static const int num_workers = 1;

#define REDIRECTION_NODE_SIZE 9
#define MAX(a,b) (((a)>(b))?(a):(b))

// A region with this refcount has already been garbage collected.
#define REG_FREED -100


// -------------------------------------
// Allocators
// -------------------------------------


#ifdef BUMPALLOC
// #define DEBUG
#warning "Using bump allocator."

  char* heap_ptr = (char*)NULL;

  char* saved_heap_ptr_stack[100];
  int num_saved_heap_ptr = 0;

  // Requires -std=gnu11
  int dbgprintf(const char *format, ...)
  {
      int code = 0;
      va_list args;
      va_start(args, format);
  #ifdef DEBUG
      code = vprintf(format, args);
  #endif
      va_end(args);
      return code;
  }

  // For simplicity just use a single large slab:
  void INITALLOC() {
    if (! heap_ptr)
    {
      // Use a fixed address in debug mode for easy reading:
      #ifdef DEBUG
      // heap_ptr = (char*)mmap(0x010000000000, global_init_biginf_buf_size, PROT_READ|PROT_WRITE, MAP_FIXED | MAP_ANONYMOUS, -1, 0);
        heap_ptr = (char*)mmap(0x010000000000, global_init_biginf_buf_size, PROT_READ|PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
        if (heap_ptr == MAP_FAILED) {
          fprintf(stderr, "Error: mmap failed: %s\n", strerror(errno));
          abort();
        }
      #else
        heap_ptr = (char*)malloc(global_init_biginf_buf_size);
      #endif
      dbgprintf("Arena size for bump alloc: %lld\n", global_init_biginf_buf_size);
    }
    dbgprintf("BUMPALLOC/INITALLOC DONE: heap_ptr = %p\n", heap_ptr);
  }

  #ifdef DEBUG
    char* my_abort() {
      fprintf(stderr, "Error: this thread's heap was not initalized.\n");
      abort();
      return NULL;
    }
    void* ALLOC(int n) {
      if (!heap_ptr) my_abort();
      char* old = heap_ptr;
      printf("ALLOC: %d bytes, returning %p\n", n, old);
      // heap_ptr += 16 * n; // Optional padding for debugging.
      heap_ptr += n;
      return old;
    }
  #else
    // #define ALLOC(n) (do heap_ptr += n)
    void* ALLOC(int n) { char* old= heap_ptr; heap_ptr += n; return old; }
  #endif // DEBUG

  // Snapshot the current heap pointer value across all threads.
  void save_alloc_state() {
    dbgprintf("   Saving(%p): pos %d", heap_ptr, num_saved_heap_ptr);
    saved_heap_ptr_stack[num_saved_heap_ptr] = heap_ptr;
    num_saved_heap_ptr++;
    dbgprintf("\n");
  }

  void restore_alloc_state() {
    if(num_saved_heap_ptr <= 0) {
      fprintf(stderr, "Bad call to restore_alloc_state!  Saved stack empty!\ne");
      abort();
    }
    num_saved_heap_ptr--;
    dbgprintf("Restoring(%p): pos %d, discarding %p",
              saved_heap_ptr_stack[num_saved_heap_ptr], num_saved_heap_ptr, heap_ptr);
    heap_ptr = saved_heap_ptr_stack[num_saved_heap_ptr];
  }

#else
  // Regular malloc mode:
  void INITALLOC() {}

  void save_alloc_state() {}
  void restore_alloc_state() {}

#ifdef _POINTER
#define ALLOC(n) GC_MALLOC(n)
#else
#define ALLOC(n) malloc(n)
#endif

#endif // BUMPALLOC

#define ALLOC_PACKED(n) ALLOC(n)


// Could try alloca() here.  Better yet, we could keep our own,
// separate stack and insert our own code to restore the pointer
// before any function that (may have) called ALLOC_SCOPED returns.

// #define ALLOC_SCOPED() alloca(1024)
#define ALLOC_SCOPED(n) alloca(n)
// #define ALLOC_SCOPED() alloc_scoped()

// Stack allocation is either too small or blows our stack.
// We need a way to make a giant stack if we want to use alloca.
// #define ALLOC_SCOPED() ALLOC(global_init_biginf_buf_size)

// Our global pointer.  No parallelism.
// static char* stack_scoped_region;
// char* alloc_scoped() { return stack_scoped_region; }



// -------------------------------------
// Basic types
// -------------------------------------

typedef char TagTyPacked;   // Must be consistent with codegen in Target.hs
typedef char TagTyBoxed;    // Must be consistent with codegen in Target.hs
typedef long long IntTy;    // Int64 in Haskell
typedef double FloatTy;
typedef int SymTy;          // Word16 in Haskell. This could actually be a
                            // uint16_t. However, uthash's HASH_*_INT macros
                            // only work with proper int's.
typedef bool BoolTy;
typedef char* PtrTy;
typedef char* CursorTy;

// -------------------------------------
// Arenas and dictionaries
// -------------------------------------

typedef struct mem_arena {
  int ind;
  char* mem; // TODO: make this a list of chunks?
  void* reflist;
} mem_arena_t;

typedef mem_arena_t* ArenaTy;

ArenaTy alloc_arena() {
  ArenaTy ar = malloc(sizeof(mem_arena_t));
  ar->ind = 0;
  ar->mem = malloc(global_inf_buf_max_chunk_size);
  ar->reflist = 0;
  return ar;
}

void free_arena(ArenaTy ar) {
  free(ar->mem);
  // TODO: free everything in ar->reflist
  free(ar);
}

CursorTy extend_arena(ArenaTy ar, int size) {
  CursorTy ret = ar->mem + ar->ind;
  ar->ind += size;
  return ret;
}

typedef struct dict_item {
  struct dict_item * next;
  int key;
  void * ptrval;
} dict_item_t;

dict_item_t * dict_alloc(ArenaTy ar) {
  return (dict_item_t *) extend_arena(ar, sizeof(dict_item_t)); // ALLOC(sizeof(dict_item_t));
}

dict_item_t *dict_insert_ptr(ArenaTy ar, dict_item_t *ptr, SymTy key, PtrTy val) {
  dict_item_t *ret = dict_alloc(ar);
  ret->key = key;
  ret->ptrval = val;
  ret->next = ptr;
  return ret;
}

PtrTy dict_lookup_ptr(dict_item_t *ptr, SymTy key) {
  while (ptr != 0) {
    if (ptr->key == key) {
      return ptr->ptrval;
    } else {
      ptr = ptr->next;
    }
  }
  printf("Error, key %d not found!\n",key);
  exit(1);
}

// -------------------------------------
// Helpers
// -------------------------------------

char* read_benchfile_param() {
  if (global_benchfile_param == NULL) {
    fprintf(stderr, "read_benchfile_param: benchmark input file was not set!\n");
    exit(1);
  } else
    return global_benchfile_param;
}

char* read_arrayfile_param() {
  if (global_arrayfile_param == NULL) {
    fprintf(stderr, "read_arrayfile_param: array input file was not set!\n");
    exit(1);
  } else
    return global_arrayfile_param;
}


// fun fact: __ prefix is actually reserved and this is an undefined behavior.
// These functions must be provided by the code generator.
void __main_expr();


void show_usage(char** argv)
{
    printf("\n");
    printf("This binary was generated by the Gibbon compiler.\n");
    printf("\n");
    printf("Usage: %s [OPTS] [size] [iters]\n", argv[0]);

    printf("\n");
    printf("Options:\n");
    printf(" --buffer-size <bytes>      Set the buffer size (default %lld).\n", global_init_biginf_buf_size);
    printf(" --bench-input <path>       Set the input file read for benchmarking. Applies only\n");
    printf("                            IF the program was *compiled* with --bench-fun. \n");
    return;
}

double avg(const double* arr, int n)
{
    double sum = 0.0;
    for(int i=0; i<n; i++) sum += arr[i];
    return sum / (double)n;
}

double difftimespecs(struct timespec* t0, struct timespec* t1)
{
    return (double)(t1->tv_sec - t0->tv_sec)
      + ((double)(t1->tv_nsec - t0->tv_nsec) / 1000000000.0);
}

int compare_doubles(const void *a, const void *b)
{
    const double *da = (const double *) a;
    const double *db = (const double *) b;
    return (*da > *db) - (*da < *db);
}

// Exponentiation
IntTy expll(IntTy base, IntTy pow) {
    if (base == 2) {
        return (1 << pow);
    } else {
        IntTy i, result = 1;
        for (i = 0; i < pow; i++)
            result *= base;
        return result;
    }
 }

// -------------------------------------
// Symbol table
// -------------------------------------

#define global_max_symbol_len 50

// Invariant: should always be equal to max(sym_table_keys)
static SymTy global_gensym_counter = 0;

static SymTy newline_symbol = -1;
static SymTy space_symbol = -1;
static SymTy comma_symbol = -1;
static SymTy leftparen_symbol = -1;
static SymTy rightparen_symbol = -1;

typedef struct SymTable_elem {
    SymTy idx;                 /* key */
    char value[global_max_symbol_len];
    UT_hash_handle hh;         /* makes this structure hashable */
} SymTable_elem;

// important! initialize to NULL
SymTable_elem *global_sym_table = NULL;

void add_symbol(SymTy idx, char *value) {
    struct SymTable_elem *s;
    s = malloc(sizeof(struct SymTable_elem));
    s->idx = idx;
    strcpy(s->value, value);
    HASH_ADD_INT( global_sym_table, idx, s );
    if (idx > global_gensym_counter) {
        global_gensym_counter = idx;
    }
}

void set_newline(SymTy idx) {
  newline_symbol = idx;
  add_symbol(idx,"NEWLINE");
}

void set_space(SymTy idx) {
  space_symbol = idx;
  add_symbol(idx,"SPACE");
}

void set_comma(SymTy idx) {
  comma_symbol = idx;
  add_symbol(idx,"COMMA");
}

void set_leftparen(SymTy idx) {
  leftparen_symbol = idx;
  add_symbol(idx,"LEFTPAREN");
}

void set_rightparen(SymTy idx) {
  rightparen_symbol = idx;
  add_symbol(idx,"RIGHTPAREN");
}

IntTy print_symbol(SymTy idx) {
  if (idx == comma_symbol) {
    return printf(",");
  } else if (idx == newline_symbol) {
    return printf("\n");
  } else if (idx == space_symbol) {
    return printf(" ");
  } else if (idx == leftparen_symbol) {
    return printf("(");
  } else if (idx == rightparen_symbol) {
    return printf(")");
  } else {
    struct SymTable_elem *s;
    HASH_FIND_INT( global_sym_table, &idx, s );
    return printf("%s", s->value);
  }
}

SymTy gensym() {
    global_gensym_counter += 1;
    SymTy idx = global_gensym_counter;
    char value[global_max_symbol_len];
    sprintf(value, "gensym_%d",idx);
    add_symbol(idx, value);
    return idx;
}

void free_symtable() {
    struct SymTable_elem *elt, *tmp;
    HASH_ITER(hh, global_sym_table, elt, tmp) {
        HASH_DEL(global_sym_table,elt);
        free(elt);
    }
}

/*

----------------------------------------
Garbage collection
----------------------------------------

   Gibbon has "growing regions" i.e each logical region is backed by a doubly linked-list
   of smaller chunks which grows as required. In addition to actual data, each chunk
   stores some additional metadata (RegionFooter) -- to chain the chunks together in a list
   and also for garbage collection. Representation of a footer at runtime:

   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   serialized data | seq_no | size | refcount_ptr | outset_ptr | next_ptr | prev_ptr
   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

   The metadata after the serialized data serves various purposes:

   - next_ptr / prev_ptr: Point to the next and previous chunk respectively.

   - seq_no: The index of this particular chunk in the list.

   - size: Used during bounds checking to calculate the size of the next region in
     the linked list.

   - refcount and outset: Whenever an inter-region indirection is created, we record that information
     using these two fields. Suppose we have an indirection from region A that points to some chunk
     in region B. Then A's outset will store a pointer to that chunk's footer, and B's refcount will
     be bumped by 1. Note that all there's only 1 refcount cell, and 1 outset per logical region,
     and chunks only store a pointer to them.


There are two ways in which a region may be freed:

(1) Whenever it goes out of scope

  The RTS tries to free a region whenever it goes out of scope. But this doesn't always succeed as
  regions sometimes contain values that "escape". One reason why this'll happen is if there's an
  indirection from A->B, and A lives longer than B. (CSK: do we have a program to test this?).
  In such a case, when B goes out of scope it's refcount won't be 0, and the RTS won't free it.
  This brings us to (2).

(2)

  When the RTS successfully frees a region, it decrements the refcounts of all the regions it
  points to (via the outset). At the same time, if it encounters a region in the outset whoose
  refcount becomes 0 after the decrement, it calls free_region on that. This way we can be sure
  that all regions will eventually be garbage collected before the program exits.



Why is it a doubly linked-list?
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Due to way that bounds-checking works, the pointers in the outset may actually point to any
arbitrary chunk in the chain. However, we want call free_region on the first one to ensure that
all of them are GC'd. So we need pointers to traverse backward get to the first one.
'trav_to_first_chunk' accomplishes this.

 */

typedef struct Outset_elem {
    CursorTy ref;
    struct Outset_elem *prev;
    struct Outset_elem *next;
} Outset_elem;

typedef struct RegionTy_struct {
    int refcount;
    CursorTy start_ptr;
    Outset_elem *outset;
} RegionTy;

typedef struct RegionFooter_struct {
    // This sequence number is not strictly required, but helps with debugging
    // and error messages.
    int seq_no;
    IntTy size;
    int *refcount_ptr;
    Outset_elem *outset_ptr;
    CursorTy next;
    CursorTy prev;
} RegionFooter;

RegionTy *alloc_region(IntTy size) {
    // Allocate the first chunk
    IntTy total_size = size + sizeof(RegionFooter);
    CursorTy start = ALLOC_PACKED(total_size);
    if (start == NULL) {
        printf("alloc_region: malloc failed: %lld", total_size);
        exit(1);
    }
    CursorTy end = start + size;

    RegionTy *reg = malloc(sizeof(RegionTy));
    if (reg == NULL) {
        printf("alloc_region: malloc failed: %ld", sizeof(RegionTy));
        exit(1);
    }
    reg->refcount = 0;
    reg->start_ptr = start;
    reg->outset = NULL;

    // Write the footer
    RegionFooter* footer = (RegionFooter *) end;
    footer->seq_no = 1;
    footer->size = size;
    footer->refcount_ptr = &(reg->refcount);
    footer->outset_ptr = reg->outset;
    footer->next = NULL;
    footer->prev = NULL;
    *(RegionFooter *) end = *footer;

    return reg;
}

typedef struct ChunkTy_struct {
    CursorTy start_ptr;
    CursorTy end_ptr;
} ChunkTy;

ChunkTy alloc_chunk(CursorTy end_old_chunk) {
    // Get size from current footer
    RegionFooter *footer = (RegionFooter *) end_old_chunk;
    IntTy newsize = footer->size * 2;
    // See #110.
    if (newsize > global_inf_buf_max_chunk_size) {
        newsize = global_inf_buf_max_chunk_size;
    }
    IntTy total_size = newsize + sizeof(RegionFooter);

    // Allocate
    CursorTy start = ALLOC_PACKED(total_size);
    if (start == NULL) {
        printf("alloc_chunk: malloc failed: %lld", total_size);
        exit(1);
    }
    CursorTy end = start + newsize;

    #ifdef DEBUG
    printf("Allocated a chunk: %lld bytes.\n", total_size);
    #endif

    // Link the next chunk's footer
    footer->next = end;

    // Write the footer
    RegionFooter* new_footer = (RegionFooter *) end;
    new_footer->seq_no = footer->seq_no + 1;
    new_footer->size = newsize;
    new_footer->refcount_ptr = footer->refcount_ptr;
    new_footer->outset_ptr = footer->outset_ptr;
    new_footer->next = NULL;
    new_footer->prev = end_old_chunk;

    return (ChunkTy) {start , end};
}

RegionFooter* trav_to_first_chunk(RegionFooter *footer) {
    if (footer->seq_no == 1) {
        return footer;
    } else if (footer->prev == NULL) {
        fprintf(stderr, "No previous chunk found at seq_no: %d", footer->seq_no);
        return NULL;
    } else {
        trav_to_first_chunk((RegionFooter *) footer->prev);
    }
    return NULL;
}

int get_ref_count(CursorTy end_ptr) {
    RegionFooter footer = *(RegionFooter *) end_ptr;
    return *(footer.refcount_ptr);
}

// B is the pointer, and A is the pointee (i.e B -> A) --
// bump A's refcount, and update B's outset ptr.
IntTy bump_ref_count(CursorTy end_b, CursorTy end_a) {
    // Bump refcount
    RegionFooter *footer_a = (RegionFooter *) end_a;
    int refcount = *(footer_a->refcount_ptr);
    int new_refcount = refcount + 1;
    *(footer_a->refcount_ptr) = new_refcount;

    // Grab B's outset
    RegionFooter *footer_b = (RegionFooter *) end_b;
    Outset_elem *head = footer_b->outset_ptr;

    #ifdef DEBUG
    Outset_elem *elt;
    int count;
    DL_COUNT(head, elt, count);
    printf("bump_ref_count: old-refcount=%d, old-outset-len=%d:\n", refcount, count);
    assert(refcount == count);
    #endif

    // Add A to B's outset
    Outset_elem *add = malloc(sizeof(Outset_elem));
    add->ref = end_a;
    add->next = NULL;
    add->prev = NULL;
    DL_APPEND(head, add);

    // As far as I can tell, DL_APPEND updates "head" after an append. Or maybe
    // only after the first one, possibly to change NULL to some struct.
    // In any case, we update outset_ptr here.
    footer_b->outset_ptr = head;

    #ifdef DEBUG
    int new_count;
    DL_COUNT(head, elt, new_count);
    printf("bump_ref_count: new-refcount=%d, new-outset-len=%d:\n", new_refcount, new_count);
    assert(new_refcount == new_count);
    #endif

    return refcount;
}

void free_region(CursorTy end_reg) {
    RegionFooter footer = *(RegionFooter *) end_reg;
    CursorTy first_chunk = end_reg - footer.size;
    CursorTy next_chunk = footer.next;

    // Decrement refcounts of all regions `reg` points to
    if (footer.outset_ptr != NULL) {
        // Grab the outset, and decrement refcounts.
        Outset_elem *elt, *tmp;
        Outset_elem *head = (footer.outset_ptr);

        #ifdef DEBUG
        int count;
        DL_COUNT(head, elt, count);
        printf("free_region: outset-len: %d\n", count);
        #endif

        // Decrement refcounts, free regions with refcount==0 and also free
        // elements of the outset.
        DL_FOREACH_SAFE(head,elt,tmp) {
            RegionFooter *elt_footer = (RegionFooter *) elt->ref;
            *(elt_footer->refcount_ptr) = *(elt_footer->refcount_ptr) - 1;
            if (*(elt_footer->refcount_ptr) == 0) {
                // See [Why is it a doubly linked-list?] above
                RegionFooter *first_chunk = trav_to_first_chunk(elt_footer);
                if (first_chunk != NULL) {
                    free_region((CursorTy) first_chunk);
                }
            }
            DL_DELETE(head,elt);
            free(elt);
        }
    }

    // Free all chunks if recount is 0
    if (*(footer.refcount_ptr) == 0) {

        #ifdef DEBUG
        // Bookkeeping
        int num_chunks = 1;
        IntTy total_bytesize = footer.size;
        #endif

        // Indicate that this region has been garbage collected.
        *(footer.refcount_ptr) = REG_FREED;

        // Free the first chunk
        free(first_chunk);

        // Now, all the others
        while (next_chunk != NULL) {
            footer = *(RegionFooter *) next_chunk;
            free(next_chunk - footer.size);
            next_chunk = footer.next;

            #ifdef DEBUG
            num_chunks++;
            total_bytesize = total_bytesize + footer.size;
            #endif
        }

        #ifdef DEBUG
        printf("GC: Freed %lld bytes across %d chunks.\n",total_bytesize,num_chunks);
        #endif
    } else {
        #ifdef DEBUG
        printf("free_region: non-zero refcount: %d.\n", *(footer.refcount_ptr));
        #endif
    }
}

BoolTy is_big(CursorTy cur) {
    return false;
}

// -------------------------------------
// Dynamic Arrays
// -------------------------------------



/* -------------------------------------------------------------------------------- */

int main(int argc, char** argv)
{
    // parameters to parse:
    //
    //   num iterations: How many times to repeat a benchmark.
    //   tree size: An integer passes to `build_tree()`.

    struct rlimit lim;
    int code;
    if ( (code = getrlimit(RLIMIT_STACK, &lim)) ) {
      fprintf(stderr, " [gibbon rts] failed to getrlimit, code %d\n", code);
      abort();
    }

    // lim.rlim_cur = 1024LU * 1024LU * 1024LU; // 1GB stack.
    lim.rlim_cur = 512LU * 1024LU * 1024LU; // 500MB stack.
    // lim.rlim_max = lim.rlim_cur; // Normal users may only be able to decrease this.

    // WARNING: Haven't yet figured out why this doesn't work on MacOS...
    #ifndef __APPLE__
    code = setrlimit(RLIMIT_STACK, &lim);
    while (code) {
      fprintf(stderr, " [gibbon rts] Failed to set stack size to %llu, code %d\n", (unsigned long long)lim.rlim_cur, code);
      lim.rlim_cur /= 2;
      // lim.rlim_max /= 2;
      if(lim.rlim_cur < 100 * 1024) {
        fprintf(stderr, " [gibbon rts] Failed setrlimit stack size to something reasonable; giving up.\n");
        break; // abort();
      }
      int code = setrlimit(RLIMIT_STACK, &lim);
    }
    #endif

    // TODO: atoi() error checking

    int got_numargs = 0; // How many numeric arguments have we got.

    int i;
    for (i = 1; i < argc; ++i)
    {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
          show_usage(argv);
          exit(0);
        }
        else if (strcmp(argv[i], "--buffer-size") == 0 && i < argc - 1)
        {
            global_init_biginf_buf_size = atoll(argv[i + 1]);
            i++;
        }
        else if ((strcmp(argv[i], "--bench-input") == 0)) {
          if (i+1 >= argc) {
            fprintf(stderr, "Not enough arguments after --bench-input, expected <file>.\n");
            show_usage(argv);
            exit(1);
          }
          global_benchfile_param = argv[i+1];
          i++;
        }
        else if ((strcmp(argv[i], "--array-input") == 0)) {
          if (i+1 >= argc) {
            fprintf(stderr, "Not enough arguments after --array-input, expected <file>.\n");
            show_usage(argv);
            exit(1);
          }
          global_arrayfile_param = argv[i+1];
          i++;
        }
        // If present, we expect the two arguments to be <size> <iters>
        else if (got_numargs >= 2) {
            fprintf(stderr, "Extra arguments left over: ");
            for(; i < argc; i++) fprintf(stderr, "%s ", argv[i]);
            show_usage(argv);
            exit(1);
        } else {
          if (got_numargs == 0) {
            global_size_param  = atoll(argv[i]);
            got_numargs ++;
          } else {
            global_iters_param = atoll(argv[i]);
          }
        }
    }

    INITALLOC();
#ifdef BUMPALLOC
    //    save_alloc_state();
#endif
    __main_expr();

    return 0;
}

// -----------------------------------------------------------------------------
// Program starts here
// -----------------------------------------------------------------------------

typedef struct Float32Float32Prod_struct {
    FloatTy field0; // x
    FloatTy field1; // y
} Point2D;

UT_icd Point2D_icd = {sizeof(Point2D), NULL, NULL, NULL};

/*
typedef struct Array_Point2D_struct {
    Point2D *points;
    IntTy size_points;
} Array_Point2D;

Array_Point2D* new_array_point2d() {
    Array_Point2D *arr = malloc(sizeof(Array_Point2D));
    if (arr == NULL) {
        printf("malloc failed in new_array_point2d (1)\n");
        exit(1);
    }
    arr->size_points = 0;
    arr->points = malloc(MAX_NUM_POINTS * sizeof(Point2D));
    if (arr->points == NULL) {
        printf("malloc failed in new_array_point2d (2)\n");
        exit(1);
    }
    return arr;
}

void free_array_point2d(Array_Point2D *arr) {
    free(arr->points);
    free(arr);
}

void print_array_point2d(Array_Point2D *ls) {
    IntTy idx = 0;
    printf("2dpoints: %lld\n", ls->size_points);
    for (idx = 0; idx < ls->size_points; idx++) {
        printf("(%f, %f), ",
               ls->points[idx].field0,
               ls->points[idx].field1);
    }
    printf("\n");
}

*/

typedef struct Float32Float32Float32Prod_struct {
    FloatTy field0; // x
    FloatTy field1; // y
    FloatTy field2; // mass
} MassPoint;

UT_icd MassPoint_icd = {sizeof(MassPoint), NULL, NULL, NULL};

/*
typedef struct Array_MassPoint_struct {
    MassPoint *masspoints;
    IntTy size_masspoints;
} Array_MassPoint;

Array_MassPoint* new_array_masspoint() {
    Array_MassPoint *arr = malloc(sizeof(Array_MassPoint));
    if (arr == NULL) {
        printf("malloc failed in new_array_masspoint (1)\n");
        exit(1);
    }
    arr->size_masspoints = 0;
    arr->masspoints = malloc(MAX_NUM_POINTS * sizeof(MassPoint));
    if (arr->masspoints == NULL) {
        printf("malloc failed in new_array_masspoint (2)\n");
        exit(1);
    }
    return arr;
}

void free_array_masspoint(Array_MassPoint *arr) {
    free(arr->masspoints);
    free(arr);
}

void print_array_masspoint(Array_MassPoint *ls) {
    IntTy idx = 0;
    printf("masspoints: %lld\n", ls->size_masspoints);
    for (idx = 0; idx < ls->size_masspoints; idx++) {
        printf("(%f, %f, %f), ",
               ls->masspoints[idx].field0,
               ls->masspoints[idx].field1,
               ls->masspoints[idx].field2);
    }
    printf("\n");
}

*/

typedef struct Float32Float32Float32Float32Float32Prod_struct {
    FloatTy field0; // x
    FloatTy field1; // y
    FloatTy field2; // mass
    FloatTy field3; // velocity x
    FloatTy field4; // velocity y
} Particle;

UT_icd Particle_icd = {sizeof(Particle), NULL, NULL, NULL};

/*
typedef struct Array_Particle_struct {
    Particle *particles;
    IntTy size_particles;
} Array_Particle;

Array_Particle* new_array_particle() {
    Array_Particle *arr = malloc(sizeof(Array_Particle));
    if (arr == NULL) {
        printf("malloc failed in new_array_particle (1)\n");
        exit(1);
    }
    arr->size_particles = 0;
    arr->particles = malloc(MAX_NUM_POINTS * sizeof(Particle));
    if (arr->particles == NULL) {
        printf("malloc failed in new_array_particle (2)\n");
        exit(1);
    }
    return arr;
}

void free_array_particle(Array_Particle *arr) {
    free(arr->particles);
    free(arr);
}

void print_array_particle(Array_Particle *ls) {
    IntTy idx = 0;
    printf("particles: %lld\n", ls->size_particles);
    for (idx = 0; idx < ls->size_particles; idx++) {
        printf("(%f, %f, %f, %f, %f), ",
               ls->particles[idx].field0,
               ls->particles[idx].field1,
               ls->particles[idx].field2,
               ls->particles[idx].field3,
               ls->particles[idx].field4);
    }
    printf("\n");
}

*/

typedef struct Box_struct {
    FloatTy llx;
    FloatTy lly;
    FloatTy rux;
    FloatTy ruy;
} Box;

void print_box(Box *box) {
    printf("box: (%f, %f, %f, %f)\n", box->llx, box->lly, box->rux, box->ruy);
}

typedef struct CursorCursorCursorProd_struct {
    CursorTy field0;
    CursorTy field1;
    CursorTy field2;
} CursorCursorCursorProd;


// -----------------------------------------------------------------------------
// Cilk reducer stuff

void points2d_append(UT_array *ls, Point2D *p) {
    utarray_push_back(ls, &p);
}

void points2d_init(UT_array *ls) {
    utarray_new(ls, &Point2D_icd);
}

void points2d_identity(void* reducer, void* list) {
    UT_array *ls = (UT_array*) list;
    utarray_new(ls, &Point2D_icd);
}

void points2d_reduce(void* reducer, void* left, void* right) {
    UT_array *ls1 = (UT_array*) left;
    UT_array *ls2 = (UT_array*) right;
    utarray_concat(ls1, ls2);
}

void particles_append(UT_array *ls, Particle p) {
    utarray_push_back(ls, &p);
}

void particles_init(UT_array *ls) {
    utarray_new(ls, &Particle_icd);
}

void particles_identity(void* reducer, void* list) {
    UT_array *ls = (UT_array*) list;
    utarray_new(ls, &Particle_icd);
}

void particles_reduce(void* reducer, void* left, void* right) {
    printf("concating...\n");
    UT_array *ls1 = (UT_array*) left;
    UT_array *ls2 = (UT_array*) right;
    utarray_concat(ls1, ls2);
}

// -----------------------------------------------------------------------------

void twoDPtsToParticles(UT_array *dst, UT_array *ps);
void particlesToMassPoints(UT_array *dst, UT_array *ps);
FloatTy minX(UT_array *ps);
FloatTy maxX(UT_array *ps);
FloatTy minY(UT_array *ps);
FloatTy maxY(UT_array *ps);
void calcCentroid(MassPoint *dst, UT_array *ls);
void massPtsInBox(UT_array *dst, Box *box, UT_array *ps);
void accel(Point2D *dst, MassPoint *mpt, FloatTy x, FloatTy y, FloatTy m);
FloatTy dist(FloatTy a_x, FloatTy a_y, FloatTy b_x, FloatTy b_y);
BoolTy isClose(FloatTy a_x, FloatTy a_y, FloatTy b_x, FloatTy b_y);
void calcAccel_seq(Point2D *dst, MassPoint *mpt, CursorTy in_cur);
void calcAccel(Point2D *dst, MassPoint *mpt, CursorTy in_cur, IntTy c);
void mapCalcAccel(UT_array *dst, UT_array *mpts, CursorTy tr);
void mapCalcAccel_par(UT_array *dst, UT_array *mpts, CursorTy tr);
void mapCalcAccel_par2(UT_array *dst, UT_array *mpts, CursorTy tr);
void applyAccel(Particle *dst, Particle *particle, Point2D *accel);
void mapApplyAccel(UT_array *dst, UT_array *particles, UT_array *accels);
void mapApplyAccel_par(UT_array *dst, UT_array *particles, UT_array *accels);
void mapApplyAccel_par2(UT_array *dst, UT_array *particles, UT_array *accels);
void minus_point2d(Point2D *dst, Point2D *p1, Point2D *p2);
void plus_point2d(Point2D *dst, Point2D *p1, Point2D *p2);
void mult_point2d(Point2D *dst, Point2D *p1, FloatTy s);
FloatTy pbbs_length_point2d(Point2D *v);
FloatTy check(UT_array *ps);

CursorCursorCursorProd buildTree_seq(CursorTy end_out_reg, CursorTy out_cur,
                                     Box *box, UT_array *mpts);
CursorCursorCursorProd buildTree(CursorTy end_out_reg, CursorTy out_cur,
                                 Box *box, UT_array *mpts, IntTy c);
IntTy getElems(CursorTy end_in_reg, CursorTy in_cur);
CursorTy _print_BH_Tree(CursorTy p3362);

// -----------------------------------------------------------------------------

// Convert input points into particles.
void twoDPtsToParticles(UT_array *dst, UT_array *ps) {
    IntTy idx = 0;
    Point2D *point;
    Particle p;
    for (idx = 0; idx < utarray_len(ps); idx++) {
        point = (Point2D*) utarray_eltptr(ps, idx);
        p = (Particle) {point->field0, point->field1, 1.0, 0.0, 0.0};
        utarray_push_back(dst, &p);
    }
}

void particlesToMassPoints(UT_array *dst, UT_array *ps) {
    IntTy idx = 0;
    Particle *p;
    MassPoint mp;
    for (idx = 0; idx < utarray_len(ps); idx++) {
        p = (Particle*) utarray_eltptr(ps, idx);
        mp = (MassPoint) {p->field0, p->field1, p->field2};
        utarray_push_back(dst, &mp);
    }
}

FloatTy minX(UT_array *ps) {
    FloatTy acc = FLT_MAX, x;
    IntTy idx = 0;
    Particle *p;
    for (idx = 0; idx < utarray_len(ps); idx++) {
        p = (Particle*) utarray_eltptr(ps, idx);
        x = p->field0;
        if (x < acc) {
            acc = x;
        }
    }
    return acc;
}

FloatTy minY(UT_array *ps) {
    FloatTy acc = FLT_MAX, y;
    IntTy idx = 0;
    Particle *p;
    for (idx = 0; idx < utarray_len(ps); idx++) {
        p = (Particle*) utarray_eltptr(ps, idx);
        y = p->field1;
        if (y < acc) {
            acc = y;
        }
    }
    return acc;
}

FloatTy maxX(UT_array *ps) {
    FloatTy acc = -100, x;
    IntTy idx = 0;
    Particle *p;
    for (idx = 0; idx < utarray_len(ps); idx++) {
        p = (Particle*) utarray_eltptr(ps, idx);
        x = p->field0;
        if (x > acc) {
            acc = x;
        }
    }
    return acc;
}

FloatTy maxY(UT_array *ps) {
    FloatTy acc = -100, y;
    Particle *p;
    IntTy idx = 0;
    for (idx = 0; idx < utarray_len(ps); idx++) {
        p = (Particle*) utarray_eltptr(ps, idx);
        y = p->field1;
        if (y > acc) {
            acc = y;
        }
    }
    return acc;
}

void calcCentroid(MassPoint *dst, UT_array *mpts) {
    IntTy idx;
    FloatTy acc_x = 0.0, acc_y = 0.0, acc_mass = 0.0;
    MassPoint *mp;
    for (idx = 0; idx < utarray_len(mpts); idx++) {
        mp = (MassPoint*) utarray_eltptr(mpts, idx);
        acc_x += mp->field0 * mp->field2;
        acc_y += mp->field1 * mp->field2;
        acc_mass += mp->field2;
    }
    dst->field0 = acc_x;
    dst->field1 = acc_y;
    dst->field2 = acc_mass;
}

BoolTy inBox(Box *box, MassPoint *mp) {
    return
        (mp->field0 > box->llx) &&
        (mp->field1 > box->lly) &&
        (mp->field0 <= box->rux) &&
        (mp->field1 <= box->ruy);
}

void massPtsInBox(UT_array *dst, Box *box, UT_array *mpts) {
    IntTy idx;
    MassPoint *mp;
    for (idx = 0; idx < utarray_len(mpts); idx++) {
        mp = (MassPoint*) utarray_eltptr(mpts, idx);
        if (inBox(box, mp)) {
            utarray_push_back(dst, mp);
        }
    }
}

void accel(Point2D *dst, MassPoint *mpt, FloatTy x, FloatTy y, FloatTy m) {
    FloatTy dx = mpt->field0 - x;
    FloatTy dy = mpt->field1 - y;
    FloatTy rsqr = (dx * dx) + (dy * dy);
    FloatTy r = sqrt(rsqr);
    if (r < 0.05) {
        dst->field0 = 0.0;
        dst->field1 = 0.0;
    } else {
        FloatTy aabs = m / rsqr;
        dst->field0 = aabs * dx;
        dst->field1 = aabs * dy;
    }
}

FloatTy dist(FloatTy a_x, FloatTy a_y, FloatTy b_x, FloatTy b_y) {
    FloatTy d1 = (a_x - b_x);
    FloatTy d2 = (a_y - b_y);
    return (d1 * d1) + (d2 * d2);
}

BoolTy isClose(FloatTy a_x, FloatTy a_y, FloatTy b_x, FloatTy b_y) {
    return dist(a_x, a_y, b_x, b_y) < 0.01;
}

void calcAccel_seq(Point2D *dst, MassPoint *mpt, CursorTy in_cur) {
    TagTyPacked tag = *(TagTyPacked *) in_cur;
    CursorTy tail = in_cur + 1;

  switch3128:
    ;
    switch (tag) {

      case 0:
        {
            dst->field0 = 0.0;
            dst->field1 = 0.0;
            break;
        }

      case 1:
        {
            FloatTy x, y, m;
            x = *(FloatTy *) tail;
            tail += sizeof(FloatTy);
            y = *(FloatTy *) tail;
            tail += sizeof(FloatTy);
            m = *(FloatTy *) tail;
            tail += sizeof(FloatTy);

            accel(dst,mpt,x,y,m);

            return;
            break;
        }

      case 3:
        {
            CursorTy tree1, tree2, tree3, tree4;
            FloatTy x, y, m;
            IntTy total_elems;

            tree2 = *(CursorTy *) tail;
            tail += 8;
            tree3 = *(CursorTy *) tail;
            tail += 8;
            tree4 = *(CursorTy *) tail;
            tail += 8;

            x = *(FloatTy *) tail;
            tail += sizeof(FloatTy);
            y = *(FloatTy *) tail;
            tail += sizeof(FloatTy);
            m = *(FloatTy *) tail;
            tail += sizeof(FloatTy);
            total_elems = *(IntTy *) tail;
            tail += sizeof(IntTy);

            tree1 = tail;

            if(isClose(mpt->field0, mpt->field1, x, y)) {

                Point2D a1, a2, a3, a4;
                calcAccel_seq(&a1, mpt, tree1);
                calcAccel_seq(&a2, mpt, tree2);
                calcAccel_seq(&a3, mpt, tree3);
                calcAccel_seq(&a4, mpt, tree4);
                dst->field0 = (a1.field0 + a2.field0 + a3.field0 + a4.field0);
                dst->field1 = (a1.field1 + a2.field1 + a3.field1 + a4.field1);
                return;

            } else {
                accel(dst,mpt,x,y,m);
                return;
            }
            break;
        }

      case 100:
        {
            CursorTy new_in_cur = *(CursorTy *) tail;
            tag = *(TagTyPacked *) new_in_cur;
            tail = new_in_cur + 1;
            goto switch3128;
            break;
        }

      case 90:
        {
            CursorTy new_in_cur = *(CursorTy *) tail;
            tag = *(TagTyPacked *) new_in_cur;
            tail = new_in_cur + 1;
            goto switch3128;
            break;
        }

      default:
        {
            printf("calcAccel: Unknown tag: %d", tag);
            exit(1);
        }
    }
}

void calcAccel(Point2D *dst, MassPoint *mpt, CursorTy in_cur, IntTy c) {
    TagTyPacked tag = *(TagTyPacked *) in_cur;
    CursorTy tail = in_cur + 1;

  switch3128:
    ;
    switch (tag) {

      case 0:
        {
            dst->field0 = 0.0;
            dst->field1 = 0.0;
            break;
        }

      case 1:
        {
            FloatTy x, y, m;
            x = *(FloatTy *) tail;
            tail += sizeof(FloatTy);
            y = *(FloatTy *) tail;
            tail += sizeof(FloatTy);
            m = *(FloatTy *) tail;
            tail += sizeof(FloatTy);

            accel(dst,mpt,x,y,m);

            return;
            break;
        }

      case 3:
        {
            CursorTy tree1, tree2, tree3, tree4;
            FloatTy x, y, m;
            IntTy total_elems;

            tree2 = *(CursorTy *) tail;
            tail += 8;
            tree3 = *(CursorTy *) tail;
            tail += 8;
            tree4 = *(CursorTy *) tail;
            tail += 8;

            x = *(FloatTy *) tail;
            tail += sizeof(FloatTy);
            y = *(FloatTy *) tail;
            tail += sizeof(FloatTy);
            m = *(FloatTy *) tail;
            tail += sizeof(FloatTy);
            total_elems = *(IntTy *) tail;
            tail += sizeof(IntTy);

            tree1 = tail;

            if (total_elems < c) {
                return calcAccel_seq(dst, mpt, in_cur);
            }

            if(isClose(mpt->field0, mpt->field1, x, y)) {

                Point2D a1, a2, a3, a4;
                cilk_spawn calcAccel(&a1, mpt, tree1, c);
                cilk_spawn calcAccel(&a2, mpt, tree2, c);
                cilk_spawn calcAccel(&a3, mpt, tree3, c);
                calcAccel(&a4, mpt, tree4, c);
                cilk_sync;
                dst->field0 = (a1.field0 + a2.field0 + a3.field0 + a4.field0);
                dst->field1 = (a1.field1 + a2.field1 + a3.field1 + a4.field1);
                return;

            } else {
                accel(dst,mpt,x,y,m);
                return;
            }
            break;
        }

      case 100:
        {
            CursorTy new_in_cur = *(CursorTy *) tail;
            tag = *(TagTyPacked *) new_in_cur;
            tail = new_in_cur + 1;
            goto switch3128;
            break;
        }

      case 90:
        {
            CursorTy new_in_cur = *(CursorTy *) tail;
            tag = *(TagTyPacked *) new_in_cur;
            tail = new_in_cur + 1;
            goto switch3128;
            break;
        }

      default:
        {
            printf("calcAccel: Unknown tag: %d", tag);
            exit(1);
        }
    }
}

void mapCalcAccel_par(UT_array *dst, UT_array *mpts, CursorTy tr) {
    int len = utarray_len(mpts);
    utarray_reserve(dst, len);

    CILK_C_DECLARE_REDUCER(UT_array) points2d_reducer =
        CILK_C_INIT_REDUCER(UT_array,
                            points2d_reduce,
                            points2d_identity,
                            __cilkrts_hyperobject_noop_destroy);
    // Initial value omitted //;
    points2d_init(&REDUCER_VIEW(points2d_reducer));
    CILK_C_REGISTER_REDUCER(points2d_reducer);

    cilk_for (int idx = 0; idx < len; idx++) {
        Point2D p;
        MassPoint *mp = (MassPoint*) utarray_eltptr(mpts, idx);
        calcAccel_seq(&p, mp, tr);
        points2d_append(&REDUCER_VIEW(points2d_reducer), &p);
    }

    CILK_C_UNREGISTER_REDUCER(points2d_reducer);
}

void mapCalcAccel_par2(UT_array *dst, UT_array *mpts, CursorTy tr) {
    int len = utarray_len(mpts);
    cilk_for (int idx = 0; idx < len; idx++) {
        MassPoint *mp = (MassPoint*) utarray_eltptr(mpts, idx);
        Point2D *p = (Point2D*) utarray_eltptr(dst, idx);
        calcAccel_seq(p, mp, tr);
    }
}

void mapCalcAccel(UT_array *dst, UT_array *mpts, CursorTy tr) {
    IntTy idx;
    MassPoint *mp;
    Point2D p;

    for (idx = 0; idx < utarray_len(mpts); idx++) {
        mp = (MassPoint*) utarray_eltptr(mpts, idx);
        // calcAccel(&p, mp, tr, cutoff);
        calcAccel_seq(&p, mp, tr);
        utarray_push_back(dst, &p);
    }
}

void applyAccel(Particle *dst, Particle *p, Point2D *a) {
    FloatTy vx, vy, ax, ay;
    vx = p->field0;
    vy = p->field1;
    ax = a->field0;
    ay = a->field1;
    dst->field0 = p->field0;
    dst->field1 = p->field1;
    dst->field2 = p->field2;
    dst->field3 = (vx + ax) * 2.0;
    dst->field4 = (vy + ay) * 2.0;
}

void mapApplyAccel(UT_array *dst, UT_array *ps, UT_array *accels){

    if (utarray_len(ps) != utarray_len(accels)) {
        printf("mapApplyAccel: size mismatch, %d != %d", utarray_len(ps), utarray_len(accels));
        exit(1);
    }
    int len = utarray_len(ps);
    Particle *p;
    Point2D *a;
    Particle p2;

    for (int idx = 0; idx < len; idx++) {
        a = (Point2D*) utarray_eltptr(accels, idx);
        p = (Particle*) utarray_eltptr(ps, idx);
        applyAccel(&p2, p, a);
        utarray_push_back(dst, &p2);
    }
}

void mapApplyAccel_par(UT_array *dst, UT_array *ps, UT_array *accels){

    if (utarray_len(ps) != utarray_len(accels)) {
        printf("mapApplyAccel: size mismatch, %d != %d", utarray_len(ps), utarray_len(accels));
        exit(1);
    }
    IntTy len = utarray_len(ps);
    IntTy idx;

    utarray_reserve(dst, len);

    CILK_C_DECLARE_REDUCER(UT_array) particles_reducer =
        CILK_C_INIT_REDUCER(UT_array,
                            particles_reduce,
                            particles_identity,
                            __cilkrts_hyperobject_noop_destroy);
    // Initial value omitted //;
    points2d_init(&REDUCER_VIEW(particles_reducer));
    CILK_C_REGISTER_REDUCER(particles_reducer);

    cilk_for (idx = 0; idx < len; idx++) {
        Particle *p = (Particle*) utarray_eltptr(ps, idx);
        Point2D *a = (Point2D*) utarray_eltptr(accels, idx);
        Particle p3;
        applyAccel(&p3, p, a);
        particles_append(&REDUCER_VIEW(particles_reducer), p3);
    }

    CILK_C_UNREGISTER_REDUCER(particles_reducer);
}

void mapApplyAccel_par2(UT_array *dst, UT_array *ps, UT_array *accels){

    if (utarray_len(ps) != utarray_len(accels)) {
        printf("mapApplyAccel: size mismatch, %d != %d", utarray_len(ps), utarray_len(accels));
        exit(1);
    }
    IntTy len = utarray_len(ps);
    IntTy idx;

    cilk_for (idx = 0; idx < len; idx++) {
        Particle *p = (Particle*) utarray_eltptr(ps, idx);
        Point2D *a = (Point2D*) utarray_eltptr(accels, idx);
        applyAccel(p, p, a);
    }
}

FloatTy pbbs_length_point2d(Point2D *v) {
    return sqrt((v->field0*v->field0)+(v->field1*v->field1));
}

void minus_point2d(Point2D *dst, Point2D *p1, Point2D *p2) {
    dst->field0 = p1->field0 - p2->field0;
    dst->field1 = p1->field1 - p2->field1;
}

void plus_point2d(Point2D *dst, Point2D *p1, Point2D *p2) {
    dst->field0 = p1->field0 + p2->field0;
    dst->field1 = p1->field1 + p2->field1;
}

void mult_point2d(Point2D *dst, Point2D *p1, FloatTy s) {
    dst->field0 = p1->field0 * s;
    dst->field1 = p1->field1 * s;
}

FloatTy check(UT_array *ps) {
    IntTy nCheck = 10;
    FloatTy gGrav = 1.0;
    FloatTy err = 0.0;
    IntTy i, j;
    IntTy idx;

    for (i = 0; i < nCheck; i++) {
        idx = rand() % (utarray_len(ps) - 1);
        // idx = i+1;
        Point2D force = (Point2D) {0.0, 0.0};
        Point2D v = (Point2D) {0.0, 0.0};
        Point2D p1, p2;
        FloatTy r, s;

        Particle *pj, *pidx;
        pidx = (Particle*) utarray_eltptr(ps, idx);

        for(j = 0; j < utarray_len(ps); j++) {
            if (idx != j) {
                pj = (Particle*) utarray_eltptr(ps, j);
                p1 = (Point2D) {pj->field3, pj->field4};
                p2 = (Point2D) {pidx->field3, pidx->field4};
                minus_point2d(&v, &p1, &p2);
                r = pbbs_length_point2d(&v);
                s = pj->field2 * pidx->field2 * (gGrav / (r * r * r));
                mult_point2d(&v, &v, s);
                plus_point2d(&force, &force, &v);
            }
        }
        Point2D force2 = (Point2D) {pidx->field3, pidx->field4};
        minus_point2d(&force2, &force, &force2);
        FloatTy e = pbbs_length_point2d(&force2) / pbbs_length_point2d(&force);
        err += e;
    }
    return err / nCheck;
}

// -----------------------------------------------------------------------------

CursorCursorCursorProd buildTree_seq(CursorTy end_out_reg, CursorTy out_cur,
                                     Box *box, UT_array *mpts) {

    // Allocator ran out of space
    if ((out_cur + 128) > end_out_reg) {
        ChunkTy new_chunk = alloc_chunk(end_out_reg);
        CursorTy chunk_start = new_chunk.start_ptr;
        CursorTy chunk_end = new_chunk.end_ptr;

        end_out_reg = chunk_end;
        *(TagTyPacked *) out_cur = 100;
        out_cur += 1;
        *(CursorTy *) out_cur = chunk_start;
        out_cur = chunk_start;
    }

    // Construct the tree.
    IntTy len = utarray_len(mpts);
    if (len == 0) {
        // BH_Empty
        *(TagTyPacked *) out_cur = 0;
        return (CursorCursorCursorProd) {end_out_reg, out_cur, out_cur+1};
    }
    else if (len == 1) {
        // BH_Leaf
        CursorTy cur = out_cur;
        MassPoint centroid;
        calcCentroid(&centroid, mpts);
        *(TagTyPacked *) cur = 1;
        cur += 1;
        *(FloatTy *) cur = centroid.field0;
        cur += sizeof(FloatTy);
        *(FloatTy *) cur = centroid.field1;
        cur += sizeof(FloatTy);
        *(FloatTy *) cur = centroid.field2;
        cur += sizeof(FloatTy);
        return (CursorCursorCursorProd) {end_out_reg, out_cur, cur};
    } else {
        // BH_Node^

        // Get the centroid
        MassPoint centroid;
        calcCentroid(&centroid, mpts);
        // printf("centroid: (%f, %f, %f)\n", centroid.field0, centroid.field1, centroid.field2);

        // Create bounding boxes for 4 quadrants
        FloatTy mid_x, mid_y;
        mid_x = (box->llx + box->rux) / 2.0;
        mid_y = (box->lly + box->ruy) / 2.0;
        Box b1, b2, b3, b4;
        b1.llx = box->llx; b1.lly = box->lly; b1.rux = mid_x;    b1.ruy = mid_y;
        b2.llx = box->llx; b2.lly = mid_y;    b2.rux = mid_x;    b2.ruy = box->ruy;
        b3.llx = mid_x;    b3.lly = mid_y;    b3.rux = box->rux; b3.ruy = box->ruy;
        b4.llx = mid_x;    b4.lly = box->lly; b4.rux = box->rux; b4.ruy = mid_y;

        // Build the trees

        *(TagTyPacked *) out_cur = 3;
        CursorTy cur_fields = out_cur + 1;
        CursorTy cur_tree1  = cur_fields + 56;

        // tree1
        UT_array *mpts1;
        utarray_new(mpts1, &MassPoint_icd);
        massPtsInBox(mpts1, &b1, mpts);
        // print_array_masspoint(mpts1);
        CursorCursorCursorProd tree1 = buildTree_seq(end_out_reg, cur_tree1, &b1, mpts1);
        // tree2
        UT_array *mpts2;
        utarray_new(mpts2, &MassPoint_icd);
        massPtsInBox(mpts2, &b2, mpts);
        // print_array_masspoint(mpts2);
        CursorCursorCursorProd tree2 = buildTree_seq(tree1.field0, tree1.field2, &b2, mpts2);

        //tree 3
        UT_array *mpts3;
        utarray_new(mpts3, &MassPoint_icd);
        massPtsInBox(mpts3, &b3, mpts);
        // print_array_masspoint(mpts3);
        CursorCursorCursorProd tree3 = buildTree_seq(tree2.field0, tree2.field2, &b3, mpts3);

        //tree 4
        UT_array *mpts4;
        utarray_new(mpts4, &MassPoint_icd);
        massPtsInBox(mpts4, &b4, mpts);
        // print_array_masspoint(mpts4);
        CursorCursorCursorProd tree4 = buildTree_seq(tree3.field0, tree3.field2, &b4, mpts4);

        // Write the fields
        *(CursorTy *) cur_fields = tree2.field1;
        cur_fields += 8;
        *(CursorTy *) cur_fields = tree3.field1;
        cur_fields += 8;
        *(CursorTy *) cur_fields = tree4.field1;
        cur_fields += 8;
        *(FloatTy *) cur_fields = centroid.field0;
        cur_fields += sizeof(FloatTy);
        *(FloatTy *) cur_fields = centroid.field1;
        cur_fields += sizeof(FloatTy);
        *(FloatTy *) cur_fields = centroid.field2;
        cur_fields += sizeof(FloatTy);

        IntTy total_elems =
            getElems(tree1.field0, tree1.field1) +
            getElems(tree2.field0, tree2.field1) +
            getElems(tree3.field0, tree3.field1) +
            getElems(tree4.field0, tree4.field1);

        *(IntTy *) cur_fields = total_elems;
        cur_fields += sizeof(IntTy);

        // Free up memory
        utarray_free(mpts1);
        utarray_free(mpts2);
        utarray_free(mpts3);
        utarray_free(mpts4);

        return (CursorCursorCursorProd) {tree4.field0, out_cur, tree4.field2};
    }
}

CursorCursorCursorProd buildTree(CursorTy end_out_reg, CursorTy out_cur,
                                 Box *box, UT_array *mpts,
                                 IntTy c) {

    if (utarray_len(mpts) < c) {
        // printf("Cutting off: %d\n",utarray_len(mpts));
        return buildTree_seq(end_out_reg, out_cur, box, mpts);
    }

    // Allocator ran out of space
    // if ((out_cur + 54) > end_out_reg) {
    if ((out_cur + 128) >= end_out_reg) {
        ChunkTy new_chunk = alloc_chunk(end_out_reg);
        CursorTy chunk_start = new_chunk.start_ptr;
        CursorTy chunk_end = new_chunk.end_ptr;

        end_out_reg = chunk_end;
        *(TagTyPacked *) out_cur = 100;
        out_cur += 1;
        *(CursorTy *) out_cur = chunk_start;
        out_cur = chunk_start;
    }

    // Construct the tree.
    IntTy len = utarray_len(mpts);
    if (len == 0) {
        // BH_Empty
        *(TagTyPacked *) out_cur = 0;
        return (CursorCursorCursorProd) {end_out_reg, out_cur, out_cur+1};
    }
    else if (len == 1) {
        // BH_Leaf
        CursorTy cur = out_cur;
        MassPoint centroid;
        calcCentroid(&centroid, mpts);
        *(TagTyPacked *) cur = 1;
        cur += 1;
        *(FloatTy *) cur = centroid.field0;
        cur += sizeof(FloatTy);
        *(FloatTy *) cur = centroid.field1;
        cur += sizeof(FloatTy);
        *(FloatTy *) cur = centroid.field2;
        cur += sizeof(FloatTy);
        return (CursorCursorCursorProd) {end_out_reg, out_cur, cur};
    } else {
        // BH_Node^

        // Get the centroid
        MassPoint centroid;
        calcCentroid(&centroid, mpts);
        // printf("centroid: (%f, %f, %f)\n", centroid.field0, centroid.field1, centroid.field2);

        // Create bounding boxes for 4 quadrants
        FloatTy mid_x, mid_y;
        mid_x = (box->llx + box->rux) / 2.0;
        mid_y = (box->lly + box->ruy) / 2.0;
        Box b1, b2, b3, b4;
        b1.llx = box->llx; b1.lly = box->lly; b1.rux = mid_x;    b1.ruy = mid_y;
        b2.llx = box->llx; b2.lly = mid_y;    b2.rux = mid_x;    b2.ruy = box->ruy;
        b3.llx = mid_x;    b3.lly = mid_y;    b3.rux = box->rux; b3.ruy = box->ruy;
        b4.llx = mid_x;    b4.lly = box->lly; b4.rux = box->rux; b4.ruy = mid_y;

        // Build the trees
        *(TagTyPacked *) out_cur = 3;
        CursorTy cur_fields = out_cur + 1;
        CursorTy cur_tree1  = cur_fields + 56;

        // Data declarations for the trees
        CursorCursorCursorProd tree1, tree2, tree3, tree4;
        UT_array *mpts1, *mpts2, *mpts3, *mpts4;
        utarray_new(mpts1, &MassPoint_icd);
        utarray_new(mpts2, &MassPoint_icd);
        utarray_new(mpts3, &MassPoint_icd);
        utarray_new(mpts4, &MassPoint_icd);
        IntTy schedule;

        // tree1
        massPtsInBox(mpts1, &b1, mpts);
        IntTy parent_id1 = __cilkrts_get_worker_number();
        tree1 = cilk_spawn buildTree(end_out_reg, cur_tree1, &b1, mpts1, c);
        IntTy cont_id1 = __cilkrts_get_worker_number();

        if (parent_id1 == cont_id1) {
            // tree1 not stolen

            // tree2
            massPtsInBox(mpts2, &b2, mpts);
            // print_array_masspoint(mpts2);
            IntTy parent_id2 = __cilkrts_get_worker_number();
            tree2 = cilk_spawn buildTree(tree1.field0, tree1.field2, &b2, mpts2, c);
            IntTy cont_id2 = __cilkrts_get_worker_number();

            if (parent_id2 == cont_id2) {
                // tree2 not stolen

                //tree 3
                massPtsInBox(mpts3, &b3, mpts);
                // print_array_masspoint(mpts3);
                IntTy parent_id3 = __cilkrts_get_worker_number();
                tree3 = cilk_spawn buildTree(tree2.field0, tree2.field2, &b3, mpts3, c);
                IntTy cont_id3 = __cilkrts_get_worker_number();

                if (parent_id3 == cont_id3) {
                    // tree3 not stolen

                    // tree4
                    massPtsInBox(mpts4, &b4, mpts);
                    // print_array_masspoint(mpts4);
                    tree4 = buildTree(tree3.field0, tree3.field2, &b4, mpts4, c);

                    cilk_sync;

                    // SCHEDULE:
                    // ---------
                    // STOLEN:
                    // NOT_STOLEN: tree1, tree2, tree3

                    // INDIRECTIONS:
                    // -------------
                    // None

                    #ifdef DEBUG
                    printf("INDIRECTIONS[0]\n");
                    #endif

                    schedule = 0;

                } else {
                    // tree3 stolen

                    // tree4
                    RegionTy *region4 = alloc_region(global_init_inf_buf_size);
                    CursorTy reg4 = region4->start_ptr;
                    CursorTy end_reg4 = reg4 + global_init_inf_buf_size;
                    massPtsInBox(mpts4, &b4, mpts);
                    // print_array_masspoint(mpts4);
                    tree4 = buildTree(end_reg4, reg4, &b4, mpts4, c);

                    cilk_sync;

                    // SCHEDULE:
                    // ---------
                    // STOLEN: tree3
                    // NOT_STOLEN: tree1, tree2

                    // INDIRECTIONS:
                    // -------------
                    // end_tree3 -> start_tree4

                    #ifdef DEBUG
                    printf("INDIRECTIONS[1]\n");
                    #endif

                    schedule = 1;

                    CursorTy end_tree3 = tree3.field2;
                    *(TagTyPacked *) end_tree3 = 90;
                    end_tree3 += 1;
                    *(CursorTy *) end_tree3 = reg4;
                }

            } else {
                // tree2 stolen

                // tree3
                RegionTy *region3 = alloc_region(global_init_inf_buf_size);
                CursorTy reg3 = region3->start_ptr;
                CursorTy end_reg3 = reg3 + global_init_inf_buf_size;
                massPtsInBox(mpts3, &b3, mpts);
                // print_array_masspoint(mpts3);
                IntTy parent_id3 = __cilkrts_get_worker_number();
                tree3 = cilk_spawn buildTree(end_reg3, reg3, &b3, mpts3, c);
                IntTy cont_id3 = __cilkrts_get_worker_number();

                if (parent_id3 == cont_id3) {
                    // tree3 not stolen

                    // tree4
                    massPtsInBox(mpts4, &b4, mpts);
                    // print_array_masspoint(mpts4);
                    tree4 = buildTree(tree3.field0, tree3.field2, &b4, mpts4, c);

                    cilk_sync;

                    // SCHEDULE:
                    // ---------
                    // STOLEN: tree2
                    // NOT_STOLEN: tree1, tree3

                    // INDIRECTIONS:
                    // -------------
                    // end_tree2 -> start_tree3

                    #ifdef DEBUG
                    printf("INDIRECTIONS[2]\n");
                    #endif

                    schedule = 2;

                    CursorTy end_tree2 = tree2.field2;
                    *(TagTyPacked *) end_tree2 = 90;
                    end_tree2 += 1;
                    *(CursorTy *) end_tree2 = reg3;

                } else {
                    // tree3 stolen

                    // tree4
                    RegionTy *region4 = alloc_region(global_init_inf_buf_size);
                    CursorTy reg4 = region4->start_ptr;
                    CursorTy end_reg4 = reg4 + global_init_inf_buf_size;
                    massPtsInBox(mpts4, &b4, mpts);
                    // print_array_masspoint(mpts4);
                    tree4 = buildTree(end_reg4, reg4, &b4, mpts4, c);

                    cilk_sync;

                    // SCHEDULE:
                    // ---------
                    // STOLEN: tree2, tree3
                    // NOT_STOLEN: tree1

                    // INDIRECTIONS:
                    // -------------
                    // end_tree2 -> start_tree3 , end_tree3 -> start_tree4

                    #ifdef DEBUG
                    printf("INDIRECTIONS[3]\n");
                    #endif

                    schedule = 3;

                    CursorTy end_tree2 = tree2.field2;
                    *(TagTyPacked *) end_tree2 = 90;
                    end_tree2 += 1;
                    *(CursorTy *) end_tree2 = reg3;

                    CursorTy end_tree3 = tree3.field2;
                    *(TagTyPacked *) end_tree3 = 90;
                    end_tree3 += 1;
                    *(CursorTy *) end_tree3 = reg4;
                }
            }

        } else {
            // tree1 stolen

            // tree2
            RegionTy *region2 = alloc_region(global_init_inf_buf_size);
            CursorTy reg2 = region2->start_ptr;
            CursorTy end_reg2 = reg2 + global_init_inf_buf_size;
            massPtsInBox(mpts2, &b2, mpts);
            // print_array_masspoint(mpts2);
            IntTy parent_id2 = __cilkrts_get_worker_number();
            tree2 = cilk_spawn buildTree(end_reg2, reg2, &b2, mpts2, c);
            IntTy cont_id2 = __cilkrts_get_worker_number();

            if (parent_id2 == cont_id2) {
                // tree2 not stolen

                //tree 3
                massPtsInBox(mpts3, &b3, mpts);
                // print_array_masspoint(mpts3);
                IntTy parent_id3 = __cilkrts_get_worker_number();
                tree3 = cilk_spawn buildTree(tree2.field0, tree2.field2, &b3, mpts3, c);
                IntTy cont_id3 = __cilkrts_get_worker_number();

                if (parent_id3 == cont_id3) {
                    // tree3 not stolen

                    // tree4
                    massPtsInBox(mpts4, &b4, mpts);
                    // print_array_masspoint(mpts4);
                    tree4 = buildTree(tree3.field0, tree3.field2, &b4, mpts4, c);

                    cilk_sync;

                    // SCHEDULE:
                    // ---------
                    // STOLEN: tree1
                    // NOT_STOLEN: tree2, tree3

                    // INDIRECTIONS:
                    // -------------
                    // end_tree1 -> start_tree2

                    #ifdef DEBUG
                    printf("INDIRECTIONS[4]\n");
                    #endif

                    schedule = 4;

                    CursorTy end_tree1 = tree1.field2;
                    *(TagTyPacked *) end_tree1 = 90;
                    end_tree1 += 1;
                    *(CursorTy *) end_tree1 = reg2;

                } else {
                    // tree3 stolen

                    // tree4
                    RegionTy *region4 = alloc_region(global_init_inf_buf_size);
                    CursorTy reg4 = region4->start_ptr;
                    CursorTy end_reg4 = reg4 + global_init_inf_buf_size;
                    massPtsInBox(mpts4, &b4, mpts);
                    // print_array_masspoint(mpts4);
                    tree4 = buildTree(end_reg4, reg4, &b4, mpts4, c);

                    cilk_sync;

                    // SCHEDULE:
                    // ---------
                    // STOLEN: tree1, tree3
                    // NOT_STOLEN: tree2

                    // INDIRECTIONS:
                    // -------------
                    // end_tree1 -> start_tree2, end_tree3 -> start_tree4

                    #ifdef DEBUG
                    printf("INDIRECTIONS[5]\n");
                    #endif

                    schedule = 5;

                    CursorTy end_tree1 = tree1.field2;
                    *(TagTyPacked *) end_tree1 = 90;
                    end_tree1 += 1;
                    *(CursorTy *) end_tree1 = reg2;

                    CursorTy end_tree3 = tree3.field2;
                    *(TagTyPacked *) end_tree3 = 90;
                    end_tree3 += 1;
                    *(CursorTy *) end_tree3 = reg4;
                }

            } else {
                // tree2 stolen

                // tree3
                RegionTy *region3 = alloc_region(global_init_inf_buf_size);
                CursorTy reg3 = region3->start_ptr;
                CursorTy end_reg3 = reg3 + global_init_inf_buf_size;
                massPtsInBox(mpts3, &b3, mpts);
                // print_array_masspoint(mpts3);
                IntTy parent_id3 = __cilkrts_get_worker_number();
                tree3 = cilk_spawn buildTree(end_reg3, reg3, &b3, mpts3, c);
                IntTy cont_id3 = __cilkrts_get_worker_number();

                if (parent_id3 == cont_id3) {
                    // tree3 not stolen

                    // tree4
                    massPtsInBox(mpts4, &b4, mpts);
                    // print_array_masspoint(mpts4);
                    tree4 = buildTree(tree3.field0, tree3.field2, &b4, mpts4, c);

                    cilk_sync;

                    // SCHEDULE:
                    // ---------
                    // STOLEN: tree1, tree2
                    // NOT_STOLEN: tree3

                    // INDIRECTIONS:
                    // -------------
                    // end_tree1 -> start_tree2, end_tree2 -> start_tree3

                    #ifdef DEBUG
                    printf("INDIRECTIONS[6]\n");
                    #endif

                    schedule = 6;

                    CursorTy end_tree1 = tree1.field2;
                    *(TagTyPacked *) end_tree1 = 90;
                    end_tree1 += 1;
                    *(CursorTy *) end_tree1 = reg2;

                    CursorTy end_tree2 = tree2.field2;
                    *(TagTyPacked *) end_tree2 = 90;
                    end_tree2 += 1;
                    *(CursorTy *) end_tree2 = reg3;

                } else {
                    // tree3 stolen

                    // tree4
                    RegionTy *region4 = alloc_region(global_init_inf_buf_size);
                    CursorTy reg4 = region4->start_ptr;
                    CursorTy end_reg4 = reg4 + global_init_inf_buf_size;
                    massPtsInBox(mpts4, &b4, mpts);
                    // print_array_masspoint(mpts4);
                    tree4 = buildTree(end_reg4, reg4, &b4, mpts4, c);

                    cilk_sync;

                    // SCHEDULE:
                    // ---------
                    // STOLEN: tree1, tree2, tree3
                    // NOT_STOLEN:

                    // INDIRECTIONS:
                    // -------------
                    // end_tree1 -> start_tree2, end_tree2 -> start_tree3, end_tree3 -> start_tree4

                    #ifdef DEBUG
                    printf("INDIRECTIONS[7]\n");
                    #endif

                    schedule = 7;

                    CursorTy end_tree1 = tree1.field2;
                    *(TagTyPacked *) end_tree1 = 90;
                    end_tree1 += 1;
                    *(CursorTy *) end_tree1 = reg2;

                    CursorTy end_tree2 = tree2.field2;
                    *(TagTyPacked *) end_tree2 = 90;
                    end_tree2 += 1;
                    *(CursorTy *) end_tree2 = reg3;

                    CursorTy end_tree3 = tree3.field2;
                    *(TagTyPacked *) end_tree3 = 90;
                    end_tree3 += 1;
                    *(CursorTy *) end_tree3 = reg4;

                }
            }
        }

        // Possible schedules:
        // | t1 | t2 | t3 | Ran with uniform_2d_100000.txt ? |
        // |----+----+----+----------------------------------|
        // |  0 |  0 |  0 | yes                              |
        // |  0 |  0 |  1 | yes                              |
        // |  0 |  1 |  0 | yes                              |
        // |  0 |  1 |  1 | yes                              |
        // |  1 |  0 |  0 | yes                              |
        // |  1 |  0 |  1 | yes                              |
        // |  1 |  1 |  0 | yes                              |
        // |  1 |  1 |  1 | yes                              |

        // The above code writes indirections, but doesn't write random access nodes
        // or the other float fields. Do that here.

        // Write the fields
        *(CursorTy *) cur_fields = tree2.field1;
        cur_fields += 8;
        *(CursorTy *) cur_fields = tree3.field1;
        cur_fields += 8;
        *(CursorTy *) cur_fields = tree4.field1;
        cur_fields += 8;
        *(FloatTy *) cur_fields = centroid.field0;
        cur_fields += sizeof(FloatTy);
        *(FloatTy *) cur_fields = centroid.field1;
        cur_fields += sizeof(FloatTy);
        *(FloatTy *) cur_fields = centroid.field2;
        cur_fields += sizeof(FloatTy);

        IntTy total_elems =
            getElems(tree1.field0, tree1.field1) +
            getElems(tree2.field0, tree2.field1) +
            getElems(tree3.field0, tree3.field1) +
            getElems(tree4.field0, tree4.field1);

        *(IntTy *) cur_fields = total_elems;
        cur_fields += sizeof(IntTy);

        // Free up memory
        utarray_free(mpts1);
        utarray_free(mpts2);
        utarray_free(mpts3);
        utarray_free(mpts4);

        // printf("schedule: %lld\n", schedule);

        return (CursorCursorCursorProd) {tree4.field0, out_cur, tree4.field2};

    }
}

IntTy getElems(CursorTy end_in_reg, CursorTy in_cur) {
    TagTyPacked tag = *(TagTyPacked *) in_cur;
    CursorTy tail = in_cur + 1;

  switch3128:
    ;
    switch (tag) {

      case 0:
        {
            return 0;
            break;
        }

      case 1:
        {
            return 1;
            break;
        }

      case 3:
        {
            tail += 48;
            IntTy n = *(IntTy *) tail;
            return n;
        }

      case 100:
        {
            CursorTy new_in_cur = *(CursorTy *) tail;
            tag = *(TagTyPacked *) new_in_cur;
            tail = new_in_cur + 1;
            goto switch3128;
            break;
        }

      case 90:
        {
            CursorTy new_in_cur = *(CursorTy *) tail;
            tag = *(TagTyPacked *) new_in_cur;
            tail = new_in_cur + 1;
            goto switch3128;
            break;
        }
      default:
       {
           printf("getElems: Unknown tag: %d", tag);
           exit(1);
       }
    }
    return 0;
}

CursorTy _print_BH_Tree(CursorTy p3362) {
    fflush(stdout);
    TagTyPacked tag3363 = *(TagTyPacked *) p3362;
    CursorTy tail3364 = p3362 + 1;


  switch3398:
    ;
    switch (tag3363) {

      case 0:
        {
            fputs("(BH_Empty ", stdout);
            fputs(")", stdout);
            return tail3364;
            break;
        }

      case 1:
        {
            fputs("(BH_Leaf ", stdout);

            FloatTy val3365 = *(FloatTy *) tail3364;
            CursorTy tail3366 = tail3364 + sizeof(FloatTy);

            printf("%f", val3365);
            fputs(" ", stdout);

            FloatTy val3367 = *(FloatTy *) tail3366;
            CursorTy tail3368 = tail3366 + sizeof(FloatTy);

            printf("%f", val3367);
            fputs(" ", stdout);

            FloatTy val3369 = *(FloatTy *) tail3368;
            CursorTy tail3370 = tail3368 + sizeof(FloatTy);

            printf("%f", val3369);
            fputs(")", stdout);
            return tail3370;
            break;
        }

      case 2:
        {
            fputs("(BH_Node ", stdout);

            FloatTy val3371 = *(FloatTy *) tail3364;
            CursorTy tail3372 = tail3364 + sizeof(FloatTy);

            printf("%f", val3371);
            fputs(" ", stdout);

            FloatTy val3373 = *(FloatTy *) tail3372;
            CursorTy tail3374 = tail3372 + sizeof(FloatTy);

            printf("%f", val3373);
            fputs(" ", stdout);

            FloatTy val3375 = *(FloatTy *) tail3374;
            CursorTy tail3376 = tail3374 + sizeof(FloatTy);

            printf("%f", val3375);
            fputs(" ", stdout);

            IntTy val3377 = *(IntTy *) tail3376;
            CursorTy tail3378 = tail3376 + sizeof(IntTy);

            printf("%lld", val3377);
            fputs(" ", stdout);

            CursorTy tail3379 =  _print_BH_Tree(tail3378);

            fputs(" ", stdout);

            CursorTy tail3380 =  _print_BH_Tree(tail3379);

            fputs(" ", stdout);

            CursorTy tail3381 =  _print_BH_Tree(tail3380);

            fputs(" ", stdout);

            CursorTy tail3382 =  _print_BH_Tree(tail3381);

            fputs(")", stdout);
            return tail3382;
            break;
        }

      case 3:
        {
            fputs("(BH_Node^ ", stdout);

            CursorTy tail3383 = tail3364 + 8;
            CursorTy tail3384 = tail3383 + 8;
            CursorTy tail3385 = tail3384 + 8;
            FloatTy val3386 = *(FloatTy *) tail3385;
            CursorTy tail3387 = tail3385 + sizeof(FloatTy);

            printf("%f", val3386);
            fputs(" ", stdout);

            FloatTy val3388 = *(FloatTy *) tail3387;
            CursorTy tail3389 = tail3387 + sizeof(FloatTy);

            printf("%f", val3388);
            fputs(" ", stdout);

            FloatTy val3390 = *(FloatTy *) tail3389;
            CursorTy tail3391 = tail3389 + sizeof(FloatTy);

            printf("%f", val3390);
            fputs(" ", stdout);

            IntTy val3392 = *(IntTy *) tail3391;
            CursorTy tail3393 = tail3391 + sizeof(IntTy);

            printf("%lld", val3392);
            fputs(" ", stdout);

            CursorTy tail3394 =  _print_BH_Tree(tail3393);

            fputs(" ", stdout);

            CursorTy tail3395 =  _print_BH_Tree(tail3394);

            fputs(" ", stdout);

            CursorTy tail3396 =  _print_BH_Tree(tail3395);

            fputs(" ", stdout);

            CursorTy tail3397 =  _print_BH_Tree(tail3396);

            fputs(")", stdout);
            return tail3397;
            break;
        }

      case 100:
        {
            fputs(" -> ", stdout);

            CursorTy tmpcur3431 = *(CursorTy *) tail3364;
            CursorTy tmpaftercur3432 = tail3364 + 8;
            TagTyPacked tagtmp3433 = *(TagTyPacked *) tmpcur3431;
            CursorTy tailtmp3434 = tmpcur3431 + 1;

            tag3363 = tagtmp3433;
            tail3364 = tailtmp3434;
            goto switch3398;
            break;
        }

      case 90:
        {
            fputs(" -> ", stdout);

            CursorTy tmpcur3431 = *(CursorTy *) tail3364;
            CursorTy tmpaftercur3432 = tail3364 + 8;
            TagTyPacked tagtmp3433 = *(TagTyPacked *) tmpcur3431;
            CursorTy tailtmp3434 = tmpcur3431 + 1;

            tag3363 = tagtmp3433;
            tail3364 = tailtmp3434;
            goto switch3398;
        }

      default:
        {
            printf("_print_BH_Tree: Unknown tag: %d", tag3363);
            exit(1);
        }
    }
}

// -----------------------------------------------------------------------------

void __main_expr() {
    // Read --array-input
    UT_array *pts;
    utarray_new(pts, &Point2D_icd);
    FILE * fp;
    char *line = NULL;
    size_t len = 0;
    ssize_t read;
    fp = fopen(read_arrayfile_param(), "r");
    if (fp == NULL) {
        fprintf(stderr, "fopen failed\n");
        abort();
    }
    FloatTy tmp_x;
    FloatTy tmp_y;
    IntTy idx = 0;
    Point2D p;
    while ((read = getline(&line, &len, fp)) != -1) {
        int xxxx = sscanf(line, "%lf %lf", &tmp_x, &tmp_y);
        p = (Point2D) {tmp_x, tmp_y};
        utarray_push_back(pts, &p);
        idx++;
    }
    // print_array_point2d(pts);

    // Convert input points into particles
    UT_array *particles;
    utarray_new(particles, &Particle_icd);
    twoDPtsToParticles(particles, pts);
    // print_array_particle(particles);

    // Convert particles to mass points
    UT_array *mpts;
    utarray_new(mpts, &MassPoint_icd);
    particlesToMassPoints(mpts, particles);
    // print_array_masspoint(mpts);

    // Calculate the bounding box
    FloatTy llx = minX(particles);
    FloatTy lly = minY(particles);
    FloatTy rux = maxX(particles);
    FloatTy ruy = maxY(particles);
    Box box = (Box) {llx, lly, rux, ruy};

    RegionTy *region = alloc_region(global_init_inf_buf_size);
    CursorTy cur = region->start_ptr;
    CursorTy end_reg = cur + global_init_inf_buf_size;

    CursorCursorCursorProd tree;
    UT_array *accels;
    utarray_new(accels, &Point2D_icd);
    UT_array *final_particles;
    // utarray_new(final_particles, &Particle_icd);

    struct timespec begin_timed2661;
    clock_gettime(CLOCK_MONOTONIC_RAW, &begin_timed2661);

    // 2 ^ 19 == 524288
    // IntTy cutoff = 524288;
    // IntTy cutoff = 262144;
    // IntTy cutoff = 131072;
    IntTy cutoff = 65536;

    for (int i = 0; i < global_iters_param; i++) {
        tree = buildTree(end_reg,cur,&box, mpts, cutoff);
        CursorTy tr = tree.field1;
        // _print_BH_Tree(tr);
        // printf("\nbuilt tree\n");

        utarray_clear(accels);
        // utarray_clear(final_particles);

        // // sequential
        // mapCalcAccel(accels, mpts, tr);
        // mapApplyAccel(final_particles, particles, accels);

        // // parallel reducers (don't work)
        // mapCalcAccel_par(accels, mpts, tr);
        // mapApplyAccel_par(final_particles, particles, accels);

        // parallel for with mutation
        // On Swarm, cilk_for speeds up these loops by 3-4x. But most of the
        // runtime is spent on constructing the tree. So the overall effect
        // of parallelizing these loops is negligible.
        utarray_concat(accels,pts);
        mapCalcAccel_par2(accels, mpts, tr);
        mapApplyAccel_par2(particles, particles, accels);
        final_particles = particles;
    }


    printf("Elems: %lld\n", getElems(tree.field0, tree.field1));

    struct timespec end_timed2661;
    clock_gettime(CLOCK_MONOTONIC_RAW, &end_timed2661);
    double batchtime = difftimespecs(&begin_timed2661, &end_timed2661);
    double selftimed = batchtime / global_iters_param;

    printf("ITERS: %lld\n", global_iters_param);
    printf("SIZE: %lld\n", global_size_param);
    printf("BATCHTIME: %e\n", batchtime);
    printf("SELFTIMED: %e\n", selftimed);

    // print_array_particle(final_particles);
    FloatTy err = check(final_particles);
    printf("Err: %f\n",err);

    utarray_free(pts);
    utarray_free(particles);
    utarray_free(mpts);
    utarray_free(accels);
    utarray_free(final_particles);
}
