// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2025, Google
// Author: Maciej Żenczykowski

#pragma once

#include <linux/bpf.h>
#include <linux/unistd.h>
#include <sys/file.h>

#include <functional>
#include <variant>

class unique_fd {
    int fd;

  public:
    unique_fd(int fd = -1) : fd(fd) {};

    unique_fd(const unique_fd&) = delete;
    unique_fd& operator=(const unique_fd&) = delete;

    unique_fd(unique_fd&& other) noexcept : fd(other.fd) {
        other.fd = -1;
    }
    unique_fd& operator=(unique_fd&& other) noexcept {
        if (this != &other) {
            reset(other.fd);
            other.fd = -1;
        }
        return *this;
    }

    int get() const { return fd; };
    bool ok() const { return fd >= 0; };
    void reset(int _fd = -1) { if (fd >= 0) close(fd); fd = _fd; };

    ~unique_fd() {
        if (fd >= 0) close(fd);
    }
};

class borrowed_fd {
    int fd;

  public:
    borrowed_fd(int fd) : fd(fd) {};
    borrowed_fd(const unique_fd& fd) : fd(fd.get()) {};

    int get() const { return fd; }
    bool ok() const { return fd >= 0; };
};

class Error {
    int err;
    std::string msg;
  public:
    Error(int e, std::string message) : err(e), msg(std::move(message)) {};
    const std::string& message() const { return msg; };
    int code() const { return err; };
};

template <typename T>
class Result {
    std::variant<T, Error> data_;
  public:
    Result(const T& value) : data_(value) {}
    Result(Error error) : data_(error) {}

    bool ok() const { return std::holds_alternative<T>(data_); }

    T value() const { return std::get<T>(data_); }

    Error error() const { return std::get<Error>(data_); }

};

template <>
class Result<void> {
    std::variant<std::monostate, Error> data_;
  public:
    Result() : data_(std::monostate{}) {}
    Result(Error error) : data_(error) {}

    bool ok() const { return std::holds_alternative<std::monostate>(data_); }
    Error error() const { return std::get<Error>(data_); }
};

Error ErrnoErrorfV(int err, const char* fmt, va_list ap) {
    char buf[256];
    // Use vsnprintf for safe string formatting with a variable argument list
    vsnprintf(buf, sizeof(buf), fmt, ap);
    auto str = std::string(buf) + ": " + strerror(errno);
    return Error(err, str);
}

Error ErrnoErrorf(const char* fmt, ...) {
    int err = errno;
    va_list ap;
    va_start(ap, fmt);
    auto result = ErrnoErrorfV(err, fmt, ap);
    va_end(ap);
    return result;
}

#define ERROR_FROM_ERRNO(f) ErrnoErrorf("BpfMap::" f "() failed")

inline uint64_t ptr_to_u64(const void * const x) {
    return (uint64_t)(uintptr_t)x;
}

// Note: bpf_attr is a union which might have a much larger size then the anonymous struct portion
// of it that we are using.  The kernel's bpf() system call will perform a strict check to ensure
// all unused portions are zero.  It will fail with E2BIG if we don't fully zero bpf_attr.
inline int bpf(enum bpf_cmd cmd, const bpf_attr& attr) {
    return syscall(__NR_bpf, cmd, &attr, sizeof(attr));
}

// this version is meant for use with cmd's which mutate the argument
inline int bpf(enum bpf_cmd cmd, bpf_attr *attr) {
    return syscall(__NR_bpf, cmd, attr, sizeof(*attr));
}

inline int writeToMapEntry(const borrowed_fd& map_fd, const void* key, const void* value,
                           uint64_t flags) {
    return bpf(BPF_MAP_UPDATE_ELEM, {
                                            .map_fd = static_cast<__u32>(map_fd.get()),
                                            .key = ptr_to_u64(key),
                                            .value = ptr_to_u64(value),
                                            .flags = flags,
                                    });
}

inline int findMapEntry(const borrowed_fd& map_fd, const void* key, void* value) {
    return bpf(BPF_MAP_LOOKUP_ELEM, {
                                            .map_fd = static_cast<__u32>(map_fd.get()),
                                            .key = ptr_to_u64(key),
                                            .value = ptr_to_u64(value),
                                    });
}

inline int findAndDeleteMapEntry(const borrowed_fd& map_fd, const void* key, void* value) {
    return bpf(BPF_MAP_LOOKUP_AND_DELETE_ELEM, {
                                                       .map_fd = static_cast<__u32>(map_fd.get()),
                                                       .key = ptr_to_u64(key),
                                                       .value = ptr_to_u64(value),
                                               });
}

inline int deleteMapEntry(const borrowed_fd& map_fd, const void* key) {
    return bpf(BPF_MAP_DELETE_ELEM, {
                                            .map_fd = static_cast<__u32>(map_fd.get()),
                                            .key = ptr_to_u64(key),
                                    });
}

// Set 'in' to NULL to begin
//
// in/out are otherwise opaque (maybe equal), must fit max(4, sizeof(key)) bytes
//   (technically 4 for HASHes where it's a bucket nr, keysize for other map types)
// keys/values must fit count keys/values (unclear about size roundup to multiple of 8)
// count is both an input (how many to lookup) & output (how many did get looked up).
//
// Returns 0 on success, sets errno on error.
//
// Officially if an error besides EFAULT is returned it still sets count,
// but likely does not apply to ENOSYS and seccomp blocked EPERM, etc.
// ENOENT should still set count (and likely flags end of iteration).
// ENOSPC if count is too small to dump a full HASH bucket.
inline int batchLookupAndMaybeDelete(const borrowed_fd& map_fd,
                                     const void* in, void* out,
                                     void* keys, void* values,
                                     uint32_t* count, bool del) {
    bpf_attr arg = {
            .batch = {
                    .in_batch = ptr_to_u64(in),
                    .out_batch = ptr_to_u64(out),
                    .keys = ptr_to_u64(keys),
                    .values = ptr_to_u64(values),
                    .count = *count,
                    .map_fd = static_cast<__u32>(map_fd.get()),
            }
    };
    int rv = bpf(del ? BPF_MAP_LOOKUP_AND_DELETE_BATCH : BPF_MAP_LOOKUP_BATCH, &arg);
    *count = arg.batch.count;
    return rv;
}

inline int batchLookup(const borrowed_fd& map_fd, const void* in, void* out,
                       void* keys, void* values, uint32_t* count) {
    return batchLookupAndMaybeDelete(map_fd, in, out, keys, values, count, false);
}

inline int batchLookupAndDelete(const borrowed_fd& map_fd, const void* in, void* out,
                                void* keys, void* values, uint32_t* count) {
    return batchLookupAndMaybeDelete(map_fd, in, out, keys, values, count, true);
}

inline int getNextMapKey(const borrowed_fd& map_fd, const void* key, void* next_key) {
    return bpf(BPF_MAP_GET_NEXT_KEY, {
                                             .map_fd = static_cast<__u32>(map_fd.get()),
                                             .key = ptr_to_u64(key),
                                             .next_key = ptr_to_u64(next_key),
                                     });
}

inline int getFirstMapKey(const borrowed_fd& map_fd, void* firstKey) {
    return getNextMapKey(map_fd, NULL, firstKey);
}

inline int bpfFdGet(const char* pathname, uint32_t flag) {
    return bpf(BPF_OBJ_GET, {
                                    .pathname = ptr_to_u64(pathname),
                                    .file_flags = flag,
                            });
}

inline int mapRetrieveRW(const char* pathname) {
    return bpfFdGet(pathname, 0);
}

inline int mapRetrieveRO(const char* pathname) {
    return bpfFdGet(pathname, BPF_F_RDONLY);
}

// returns next id > map_id, or 0 (and sets errno)
inline uint32_t bpfGetNextMapId(const uint32_t map_id) {
    bpf_attr arg = { .start_id = map_id };
    return bpf(BPF_MAP_GET_NEXT_ID, &arg) ? 0 : arg.next_id;
}

// Note: some fields are only defined in newer kernels (ie. the map_info struct grows
// over time), so we need to check that the field we're interested in is actually
// supported/returned by the running kernel.  We do this by checking it is fully
// within the bounds of the struct size as reported by the kernel.
#define DEFINE_BPF_GET_FD(TYPE, NAME, FIELD) \
inline int bpfGetFd ## NAME(const borrowed_fd& fd) { \
    struct bpf_ ## TYPE ## _info info = {}; \
    union bpf_attr attr = { .info = { \
        .bpf_fd = static_cast<__u32>(fd.get()), \
        .info_len = sizeof(info), \
        .info = ptr_to_u64(&info), \
    }}; \
    int rv = bpf(BPF_OBJ_GET_INFO_BY_FD, &attr); \
    if (rv) return rv; \
    if (attr.info.info_len < offsetof(bpf_ ## TYPE ## _info, FIELD) + sizeof(info.FIELD)) { \
        errno = EOPNOTSUPP; \
        return -1; \
    }; \
    return info.FIELD; \
}

DEFINE_BPF_GET_FD(map, MapType, type)            // int bpfGetFdMapType(const borrowed_fd& map_fd)
DEFINE_BPF_GET_FD(map, MapId, id)                // int bpfGetFdMapId(const borrowed_fd& map_fd)
DEFINE_BPF_GET_FD(map, KeySize, key_size)        // int bpfGetFdKeySize(const borrowed_fd& map_fd)
DEFINE_BPF_GET_FD(map, ValueSize, value_size)    // int bpfGetFdValueSize(const borrowed_fd& map_fd)
DEFINE_BPF_GET_FD(map, MaxEntries, max_entries)  // int bpfGetFdMaxEntries(const borrowed_fd& map_fd)
DEFINE_BPF_GET_FD(map, MapFlags, map_flags)      // int bpfGetFdMapFlags(const borrowed_fd& map_fd)

#undef DEFINE_BPF_GET_FD

int bpfGetFdMapById(const uint32_t map_id) {
    return bpf(BPF_MAP_GET_FD_BY_ID, { .map_id = map_id });
}

Result<std::string> bpfGetFdMapName(const borrowed_fd& fd) {
    bpf_map_info info = {};
    union bpf_attr attr = { .info = {
        .bpf_fd = static_cast<__u32>(fd.get()),
        .info_len = sizeof(info),
        .info = ptr_to_u64(&info),
    }};

    int rv = bpf(BPF_OBJ_GET_INFO_BY_FD, &attr);
    if (rv) return ErrnoErrorf("BPF_OBJ_GET_INFO_BY_FD failed");

    return std::string(info.name);
}

int dup_cloexec(int oldfd) {
    if (oldfd < 0) fprintf(stderr, "dup_cloexec(%d)\n", oldfd);
    int newfd = fcntl(oldfd, F_DUPFD_CLOEXEC, 0);
    if (newfd < 0) fprintf(stderr, "dup_cloexec(%d) -> %d [%d]\n", oldfd, newfd, errno);
    return newfd;
}

// This is a class wrapper for eBPF maps. The eBPF map is a special in-kernel
// data structure that stores data in <Key, Value> pairs. It can be read/write
// from userspace by passing syscalls with the map file descriptor. This class
// is used to generalize the procedure of interacting with eBPF maps and hide
// the implementation detail from other process. Besides the basic syscalls
// wrapper, it also provides some useful helper functions as well as an iterator
// nested class to iterate the map more easily.
//
// NOTE: A kernel eBPF map may be accessed by both kernel and userspace
// processes at the same time. Or if the map is pinned as a virtual file, it can
// be obtained by multiple eBPF map class object and accessed concurrently.
// Though the map class object and the underlying kernel map are thread safe, it
// is not safe to iterate over a map while another thread or process is deleting
// from it. In this case the iteration can return duplicate entries.
template <class Key, class Value>
class BpfMapRO {
  public:
    BpfMapRO<Key, Value>() {};

    // explicitly force no copy constructor, since it would need to dup the fd
    // (later on, for testing, we still make available a copy assignment operator)
    BpfMapRO<Key, Value>(const BpfMapRO<Key, Value>&) = delete;

  protected:
    void abortOnMismatch(bool writable) const {
        if (!mMapFd.ok()) abort();

        int flags = bpfGetFdMapFlags(mMapFd);
        if (flags < 0) abort();

        if (flags & BPF_F_WRONLY) abort();

        if (writable && (flags & BPF_F_RDONLY)) abort();

        int keySize = bpfGetFdKeySize(mMapFd);
        if (keySize != sizeof(Key)) abort();

        int valueSize = bpfGetFdValueSize(mMapFd);
        if (valueSize != sizeof(Value)) abort();
    }

  public:
    explicit BpfMapRO<Key, Value>(const char* pathname) {
        mMapFd.reset(mapRetrieveRO(pathname));
        abortOnMismatch(/* writable */ false);
    }

    Result<Key> getFirstKey() const {
        Key firstKey;
        if (getFirstMapKey(mMapFd, &firstKey)) return ERROR_FROM_ERRNO("getFirstKey");
        return firstKey;
    }

    Result<Key> getNextKey(const Key& key) const {
        Key nextKey;
        if (getNextMapKey(mMapFd, &key, &nextKey)) return ERROR_FROM_ERRNO("getNextKey");
        return nextKey;
    }

    Result<Value> readValue(const Key& key) const {
        Value value;
        if (findMapEntry(mMapFd, &key, &value)) return ERROR_FROM_ERRNO("readValue");
        return value;
    }

  protected:
    [[clang::reinitializes]] Result<void> init(const char* path, int fd, bool writable) {
        mMapFd.reset(fd);
        if (!mMapFd.ok()) return ErrnoErrorf("Pinned map not accessible or does not exist: ({})", path);
        // Normally we should return an error here instead of calling abort,
        // but this cannot happen at runtime without a massive code bug (K/V type mismatch)
        // and as such it's better to just blow the system up and let the developer fix it.
        // Crashes are much more likely to be noticed than logs and missing functionality.
        abortOnMismatch(writable);
        return {};
    }

    // Observed 4 <= sizeof(Key) <= 16 (48 for Java), 1 <= sizeof(Value) <= 32 (64 for Java)
    // You can uncomment the following to check:
    //   static_assert(sizeof(Key) >= 4);
    //   static_assert(sizeof(Key) <= 16); // 48 observed, but not in C++
    //   static_assert(sizeof(Value) >= 1);
    //   static_assert(sizeof(Value) <= 32); // 64 observed, but not in C++

    // ~16KiB initial stack usage seems reasonable
    static constexpr int BATCHSIZE = 16384 / (sizeof(Key) + sizeof(Value));
    static_assert(BATCHSIZE >= 256, "consider Key/Value size, whether incr mem limit, decr batch req");
    static_assert(BATCHSIZE * sizeof(Key) + BATCHSIZE * sizeof(Value) <= 16384);

    Result<void> doBulkLookupAndMaybeDelete(bool del, const std::function<void(const Key &, const Value &)> &f) const {
        union { Key k; uint32_t nr; } batch;
        bool first = true;

        // starting with N == 1 fails with -28/ENOSPC in:
        //   BpfNetworkStatsTest.cpp BpfNetworkStatsHelperTest#TestGetStatsSortedAndGrouped
        // requiring us to loop back around, kernel code itself claims that in practice 5
        // is almost always enough for a bucket (which is what you'd expect, it's not a good
        // hashtable if there's lots of items in a single bucket)
        //
        // Since we start with 256+ we shouldn't ever actually need to increase N...
        // Also note that the 'true' condition is not really an infinite loop,
        // as we'll blow up the stack and crash instead of looping infinitely.
        // But that also shouldn't happen cause it would imply/require a ridiculously
        // large bpf map sitting entirely in one bucket...
        for (int N = BATCHSIZE; true; N *= 2) {
            // N is how many we have space for, can grow on demand as needed
            Key keys[N];
            Value values[N];
            for (;;) {
                uint32_t count = N; // how many to fetch (and possibly delete)
                int rv = batchLookupAndMaybeDelete(mMapFd, first ? NULL : &batch, &batch, &keys, &values, &count, del);
                if (rv && errno == ENOSPC) break;  // not enough space for full HASH bucket, go around the *outer* loop
                if (rv && errno != ENOENT) return ERROR_FROM_ERRNO("doBulkLookup&Del");
                // count is now how many *were* fetched (and possibly delete)
                for (unsigned i = 0; i < count; ++i) f(keys[i], values[i]);
                if (rv) return {};  // ENOENT -> success
                first = false;
            }
        }
    }

  public:
    // Function that tries to get map from a pinned path.
    [[clang::reinitializes]] Result<void> init(const char* path) {
        return init(path, mapRetrieveRO(path), /* writable */ false);
    }

    // For all keys in the map call filter() - unless it errors out.
    Result<void> iterate(const std::function<Result<void>(const Key &)> &filter) const {
        Result<Key> curKey = getFirstKey();
        while (curKey.ok()) {
            const Result<Key> &nextKey = getNextKey(curKey.value());
            Result<void> status = filter(curKey.value());
            if (!status.ok()) return status;
            curKey = nextKey;
        }
        if (curKey.error().code() == ENOENT) return {};
        return curKey.error();
    }

    // Does not allow early termination (via f erroring out) - may be implemented with bulk api
    Result<void> forAll(const std::function<void(const Key &)> &f) const {
        // No kernel bpfmap bulk lookup api which doesn't return both keys & values.
        return doBulkLookupAndMaybeDelete(/*delete*/ false,
            [&f](const Key &key, const Value &) {
                f(key);
            }
        );
    }

    // For all (key, value) pairs in the map call filter() - unless it errors out.
    Result<void> iterate(const std::function<Result<void>(const Key &, const Value &)> &filter) const {
        Result<Key> curKey = getFirstKey();
        while (curKey.ok()) {
            const Result<Key> &nextKey = getNextKey(curKey.value());
            Result<Value> curValue = readValue(curKey.value());
            if (!curValue.ok()) return curValue.error();
            Result<void> status = filter(curKey.value(), curValue.value());
            if (!status.ok()) return status;
            curKey = nextKey;
        }
        if (curKey.error().code() == ENOENT) return {};
        return curKey.error();
    }

    // Does not allow early termination (via f erroring out)
    Result<void> forAll(const std::function<void(const Key &, const Value &)> &f) const {
        return doBulkLookupAndMaybeDelete(/*delete*/ false, f);
    }

    BpfMapRO<Key, Value>& operator=(const BpfMapRO<Key, Value>&) = delete;
    BpfMapRO<Key, Value>& operator=(BpfMapRO<Key, Value>&& other) = delete;

    // Note that unique_fd.reset() carefully saves and restores the errno,
    // and BpfMap.reset() won't touch the errno if passed in fd is negative either,
    // hence you can do something like BpfMap.reset(systemcall()) and then
    // check BpfMap.isValid() and look at errno and see why systemcall() failed.
    [[clang::reinitializes]] void reset(int fd) {
        mMapFd.reset(fd);
        if (mMapFd.ok()) abortOnMismatch(/* writable */ false);  // false isn't ideal
    }

    // unique_fd has an implicit int conversion defined, which combined with the above
    // reset(int) would result in double ownership of the fd, hence we either need a custom
    // implementation of reset(unique_fd), or to delete it and thus cause compile failures
    // to catch this and prevent it.
    void reset(unique_fd fd) = delete;

    [[clang::reinitializes]] void reset() {
        mMapFd.reset();
    }

    bool isValid() const { return mMapFd.ok(); }

    Result<bool> isEmpty() const {
        auto key = getFirstKey();
        if (key.ok()) return false;
        if (key.error().code() == ENOENT) return true;
        return key.error();
    }

  protected:
    unique_fd mMapFd;
};

template <class Key, class Value>
class BpfMapRW : public BpfMapRO<Key, Value> {
  protected:
    using BpfMapRO<Key, Value>::mMapFd;
    using BpfMapRO<Key, Value>::abortOnMismatch;

  public:
    using BpfMapRO<Key, Value>::BpfMapRO;

    explicit BpfMapRW<Key, Value>(const char* pathname) {
        mMapFd.reset(mapRetrieveRW(pathname));
        abortOnMismatch(/* writable */ true);
    }

    // Function that tries to get map from a pinned path.
    [[clang::reinitializes]] Result<void> init(const char* path) {
        return BpfMapRO<Key,Value>::init(path, mapRetrieveRW(path), /* writable */ true);
    }

    Result<void> writeValue(const Key& key, const Value& value, uint64_t flags) {
        if (writeToMapEntry(mMapFd, &key, &value, flags)) return ERROR_FROM_ERRNO("writeValue");
        return {};
    }
};

template <class Key, class Value>
class BpfMap : public BpfMapRW<Key, Value> {
  protected:
    using BpfMapRW<Key, Value>::mMapFd;
    using BpfMapRW<Key, Value>::doBulkLookupAndMaybeDelete;

  public:
    using BpfMapRW<Key, Value>::BpfMapRW;
    using BpfMapRW<Key, Value>::getFirstKey;
    using BpfMapRW<Key, Value>::getNextKey;
    using BpfMapRW<Key, Value>::readValue;

    Result<void> deleteValue(const Key& key) {
        if (deleteMapEntry(mMapFd, &key)) return ERROR_FROM_ERRNO("deleteValue");
        return {};
    }

    Result<Value> readAndDeleteValue(const Key& key) {
        Value value;
        if (findAndDeleteMapEntry(mMapFd, &key, &value)) return ERROR_FROM_ERRNO("read&DelVal");
        return value;
    }

    Result<void> clear() {
        while (true) {
            auto key = getFirstKey();
            if (!key.ok()) {
                if (key.error().code() == ENOENT) return {};  // empty: success
                return key.error();                           // Anything else is an error
            }
            auto res = deleteValue(key.value());
            if (!res.ok()) {
                // Someone else could have deleted the key, so ignore ENOENT
                if (res.error().code() == ENOENT) continue;
                return res.error();
            }
        }
    }

    // Does not allow early termination (via f erroring out)
    Result<void> consume(const std::function<void(const Key&, const Value&)>& f) {
        return doBulkLookupAndMaybeDelete(/*delete*/true, f);
    }
};
