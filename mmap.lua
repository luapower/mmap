
--memory mapping API Windows, Linux and OSX
--Written by Cosmin Apreutesei. Public Domain.

local ffi = require'ffi'
local bit = require'bit'
local C = ffi.C
local mmap = {C = C}

function mmap.aligned_size(size)
	local pagesize = mmap.pagesize()
	local fpagecount = size / pagesize
	local pagecount = math.floor(fpagecount)
	return (pagecount + (pagecount < fpagecount and 1 or 0)) * pagesize
end

local function parseopt(t)
	assert(type(t) == 'table', 'options table expected')

	local access = t.access or ''
	local access_write = access:find'w'
	local access_copy = access:find'c'
	local access_exec = access:find'x'
	local size = t.size
	local offset = t.offset or 0

	assert(not (access_write and access_copy),
		'w and c access flags are mutually exclusive')
	assert(t.fileno or t.path or t.name or t.size, 'size expected when mapping the pagefile')
	assert(not (t.fileno and t.path), 'fileno and path are mutually exclusive')
	assert(not size or size > 0, 'size must be > 0')
	assert(offset >= 0, 'offset must be >= 0')
	assert(offset == mmap.aligned_size(offset), 'offset not aligned to page boundaries')

	return size, offset, access_write, access_copy, access_exec
end

if ffi.os == 'Windows' then

	--winapi types

	ffi.cdef('typedef '..(ffi.abi'64bit' and 'int64_t' or 'int32_t')..' ULONG_PTR;')

	ffi.cdef[[
	typedef void*          HANDLE;
	typedef int16_t        WORD;
	typedef int32_t        DWORD, *LPDWORD;
	typedef uint32_t       UINT;
	typedef int            BOOL;
	typedef ULONG_PTR      SIZE_T;
	typedef void           VOID, *LPVOID;
	typedef const void*    LPCVOID;
	typedef char*          LPSTR;
	typedef const char*    LPCSTR;
	typedef wchar_t*       LPWSTR;
	typedef const wchar_t* LPCWSTR;
	]]

	--error reporting

	ffi.cdef[[
	DWORD GetLastError(void);

	DWORD FormatMessageA(
		DWORD dwFlags,
		LPCVOID lpSource,
		DWORD dwMessageId,
		DWORD dwLanguageId,
		LPSTR lpBuffer,
		DWORD nSize,
		va_list *Arguments
	);
	]]

	local FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000

	local ERROR_FILE_NOT_FOUND     = 0x0002
	local ERROR_NOT_ENOUGH_MEMORY  = 0x0008
	local ERROR_INVALID_PARAMETER  = 0x0057
	local ERROR_DISK_FULL          = 0x0070
	local ERROR_INVALID_ADDRESS    = 0x01E7
	local ERROR_FILE_INVALID       = 0x03ee
	local ERROR_COMMITMENT_LIMIT   = 0x05af
	local ERROR_MAPPED_ALIGNMENT   = 0x046c

	local errcodes = {
		[ERROR_FILE_NOT_FOUND] = 'not_found',
		[ERROR_NOT_ENOUGH_MEMORY] = 'file_too_short', --readonly file too short
		[ERROR_INVALID_PARAMETER] = 'out_of_mem', --size too large for available memory
		[ERROR_DISK_FULL] = 'disk_full',
		[ERROR_COMMITMENT_LIMIT] = 'file_too_short', --swapfile too short
		[ERROR_FILE_INVALID] = 'file_too_short', --file has zero size
		[ERROR_INVALID_ADDRESS] = 'invalid_address',
		[ERROR_MAPPED_ALIGNMENT] = 'invalid_offset', --offset not aligned
	}

	local function reterr(msgid)
		local msgid = msgid or C.GetLastError()
		local bufsize = 256
		local buf = ffi.new('char[?]', bufsize)
		local sz = C.FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM, nil, msgid, 0, buf, bufsize, nil)
		if sz == 0 then return 'Unknown Error' end
		return nil, ffi.string(buf, sz), errcodes[msgid] or msgid
	end

	--pagesize

	ffi.cdef[[
	typedef struct {
		WORD wProcessorArchitecture;
		WORD wReserved;
		DWORD dwPageSize;
		LPVOID lpMinimumApplicationAddress;
		LPVOID lpMaximumApplicationAddress;
		LPDWORD dwActiveProcessorMask;
		DWORD dwNumberOfProcessors;
		DWORD dwProcessorType;
		DWORD dwAllocationGranularity;
		WORD wProcessorLevel;
		WORD wProcessorRevision;
	} SYSTEM_INFO, *LPSYSTEM_INFO;

	VOID GetSystemInfo(LPSYSTEM_INFO lpSystemInfo);
	]]

	local pagesize
	function mmap.pagesize()
		if not pagesize then
			local sysinfo = ffi.new'SYSTEM_INFO'
			C.GetSystemInfo(sysinfo)
			pagesize = sysinfo.dwAllocationGranularity
		end
		return pagesize
	end

	--utf8 to wide char conversion

	ffi.cdef[[
	int MultiByteToWideChar(
		  UINT     CodePage,
		  DWORD    dwFlags,
		  LPCSTR   lpMultiByteStr,
		  int      cbMultiByte,
		  LPWSTR   lpWideCharStr,
		  int      cchWideChar);
	]]

	local CP_UTF8 = 65001
	local ERROR_INSUFFICIENT_BUFFER = 122

	function wcs(s)
		local sz = C.MultiByteToWideChar(CP_UTF8, 0, s, #s + 1, nil, 0)
		local buf = ffi.new('wchar_t[?]', sz)
		C.MultiByteToWideChar(CP_UTF8, 0, s, #s + 1, buf, sz)
		return buf
	end

	--file opening and file mapping

	ffi.cdef[[
	HANDLE mmap_CreateFileW(
		LPCWSTR lpFileName,
		DWORD dwDesiredAccess,
		DWORD dwShareMode,
		LPVOID lpSecurityAttributes,
		DWORD dwCreationDisposition,
		DWORD dwFlagsAndAttributes,
		HANDLE hTemplateFile
	) asm("CreateFileW");

	BOOL mmap_GetFileSizeEx(
	  HANDLE         hFile,
	  int64_t*       lpFileSize
	) asm("GetFileSizeEx");

	HANDLE mmap_CreateFileMappingW(
		HANDLE hFile,
		LPVOID lpFileMappingAttributes,
		DWORD flProtect,
		DWORD dwMaximumSizeHigh,
		DWORD dwMaximumSizeLow,
		const wchar_t *lpName
	) asm("CreateFileMappingW");

	void* MapViewOfFileEx(
		HANDLE hFileMappingObject,
		DWORD dwDesiredAccess,
		DWORD dwFileOffsetHigh,
		DWORD dwFileOffsetLow,
		SIZE_T dwNumberOfBytesToMap,
		LPVOID lpBaseAddress
	);
	BOOL UnmapViewOfFile(LPCVOID lpBaseAddress);
	BOOL FlushViewOfFile(LPCVOID lpBaseAddress, SIZE_T dwNumberOfBytesToFlush);
	BOOL FlushFileBuffers(HANDLE hFile);
	BOOL CloseHandle(HANDLE hObject);

	BOOL mmap_SetFilePointerEx(
	  HANDLE         hFile,
	  int64_t        liDistanceToMove,
	  int64_t*       lpNewFilePointer,
	  DWORD          dwMoveMethod
	) asm("SetFilePointerEx");

	BOOL SetEndOfFile(HANDLE hFile);
	]]

	local INVALID_HANDLE_VALUE = ffi.cast('HANDLE', -1)

	--CreateFile dwDesiredAccess flags
	local GENERIC_READ    = 0x80000000
	local GENERIC_WRITE   = 0x40000000
	local GENERIC_EXECUTE = 0x20000000

	--CreateFile dwShareMode flags
	local FILE_SHARE_READ        = 0x00000001
	local FILE_SHARE_WRITE       = 0x00000002
	local FILE_SHARE_DELETE      = 0x00000004

	--CreateFile dwCreationDisposition flags
	--local CREATE_NEW        = 1
	--local CREATE_ALWAYS     = 2
	local OPEN_EXISTING     = 3
	local OPEN_ALWAYS       = 4
	--local TRUNCATE_EXISTING = 5

	--local STANDARD_RIGHTS_REQUIRED = 0x000F0000
	--local STANDARD_RIGHTS_ALL      = 0x001F0000

	--local PAGE_NOACCESS          = 0x001
	local PAGE_READONLY          = 0x002
	local PAGE_READWRITE         = 0x004
	--local PAGE_WRITECOPY         = 0x008
	--local PAGE_EXECUTE           = 0x010
	local PAGE_EXECUTE_READ      = 0x020 --XP SP2+
	local PAGE_EXECUTE_READWRITE = 0x040 --XP SP2+
	--local PAGE_EXECUTE_WRITECOPY = 0x080 --Vista SP1+
	--local PAGE_GUARD             = 0x100
	--local PAGE_NOCACHE           = 0x200
	--local PAGE_WRITECOMBINE      = 0x400

	--local SECTION_QUERY                = 0x0001
	local SECTION_MAP_WRITE            = 0x0002
	local SECTION_MAP_READ             = 0x0004
	local SECTION_MAP_EXECUTE          = 0x0008
	--local SECTION_EXTEND_SIZE          = 0x0010
	--local SECTION_MAP_EXECUTE_EXPLICIT = 0x0020

	local FILE_MAP_WRITE      = SECTION_MAP_WRITE
	local FILE_MAP_READ       = SECTION_MAP_READ
	local FILE_MAP_COPY       = 0x00000001
	--local FILE_MAP_RESERVE    = 0x80000000
	--local FILE_MAP_EXECUTE    = SECTION_MAP_EXECUTE_EXPLICIT --XP SP2+

	local m = ffi.new(ffi.typeof[[
		union {
			struct { int32_t lo; int32_t hi; };
			uint64_t x;
		}
	]])
	local function split_uint64(x)
		m.x = x
		return m.hi, m.lo
	end

	function mmap.map(t)
		local size, offset, access_write, access_copy, access_exec = parseopt(t)

		local hfile, own_hfile
		if t.fileno then
			hfile = t.fileno
		elseif t.path then
			local access = bit.bor(
				GENERIC_READ,
				access_write and GENERIC_WRITE or 0,
				access_exec and GENERIC_EXECUTE or 0)
			local sharemode = bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE)
			local creationdisp = access_write and OPEN_ALWAYS or OPEN_EXISTING
			local flagsandattrs = 0
			local h = C.mmap_CreateFileW(wcs(t.path), access, sharemode, nil, creationdisp, flagsandattrs, nil)
			if h == INVALID_HANDLE_VALUE then
				return reterr()
			end
			hfile = h
			own_hfile = true
		end

		--flush the buffers before mapping otherwise we won't see the current
		--view of the file (Windows).
		if hfile and not own_hfile then
			local ok = C.FlushFileBuffers(hfile) == 1
			if not ok then return reterr() end
		end

		local function close_file()
			local close_file = t.close_file
			if close_file == nil then close_file = own_hfile end
			if not close_file then return end
			C.CloseHandle(hfile)
			if t.remove_file then
				C.remove_file()
			end
		end

		local protect = bit.bor(
			access_exec and
				(access_write and PAGE_EXECUTE_READWRITE or PAGE_EXECUTE_READ) or
				(access_write and PAGE_READWRITE or PAGE_READONLY))
		local mhi, mlo = split_uint64(size or 0) --0 means whole file
		local name = t.name and wcs('Local\\'..t.name) or nil
		local hfilemap = C.mmap_CreateFileMappingW(hfile or INVALID_HANDLE_VALUE, nil, protect, mhi, mlo, name)
		if hfilemap == nil then
			local err = C.GetLastError()
			close_file()
			return reterr(err)
		end

		local access = bit.bor(
			not access_write and not access_copy and FILE_MAP_READ or 0,
			access_write and FILE_MAP_WRITE or 0,
			access_copy and FILE_MAP_COPY or 0,
			access_exec and SECTION_MAP_EXECUTE or 0)
		local times = (t.mirrors or 0) + 1
		local ohi, olo = split_uint64(offset)
		local baseaddr = t.addr or nil
		local addr = C.MapViewOfFileEx(hfilemap, access, ohi, olo, size or 0, baseaddr)
		if addr == nil then
			local err = C.GetLastError()
			C.CloseHandle(hfilemap)
			close_file()
			return reterr(err)
		end

		local function free()
			C.UnmapViewOfFile(addr)
			C.CloseHandle(hfilemap)
			close_file()
		end

		local function flush(self, addr, sz)
			local ok = C.FlushViewOfFile(addr or self.addr, sz or 0) == 1
			if not ok then reterr() end
			return true
		end

		--if size wasn't given, get the file size so that the user always knows
		--the actual size of the mapped memory.
		if not size then
			local psz = ffi.new'int64_t[1]'
			if C.mmap_GetFileSizeEx(hfile, psz) ~= 1 then
				local err = C.GetLastError()
				free()
				return reterr(err)
			end
			size = tonumber(psz[0])
		end

		return {fileno = hfile, close_file = own_hfile, handle = hfilemap,
			addr = addr, size = size, free = free, flush = flush}
	end

elseif ffi.os == 'Linux' or ffi.os == 'OSX' then

	if ffi.os == 'OSX' then
		ffi.cdef'typedef int64_t off_t;'
	else
		ffi.cdef'typedef long int off_t;'
	end

	ffi.cdef[[
	int __getpagesize(void);

	void* mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
	int munmap(void *addr, size_t length);
	int mprotect(void *addr, size_t len, int prot);

	int shm_open(const char *name, int oflag, mode_t mode);
	int shm_unlink(const char *name);

	void unlink(char*);
	void close(int fd);
	]]

	mmap.pagesize = C.__getpagesize

	local PROT_READ  = 1
	local PROT_WRITE = 2
	local PROT_EXEC  = 4
	local MAP_PRIVATE = 2
	local MAP_ANON = ffi.os == 'Linux' and 0x20 or 0x1000

	function mmap.map(t)
		local size, offset, access_write, access_copy, access_exec = parseopt(t)

		local fd = t.fileno

		if t.name then
			local shm_path = '/dev/shm/XXXXXX'
			local tmp_path = '/tmp/XXXXXX'
			fd = mkstemp(shm_path) or mkstemp(tmp_path)
			if unlink(chosen_path) ~= 0 then
				close(fd)
				return
			end
		end

		local size = assert(t.size, 'size missing')
		local access = bit.bor(
			PROT_READ,
			t.access and bit.bor(
				t.access:find'w' and PROT_WRITE or 0,
				t.access:find'x' and PROT_EXEC or 0
			)
		)
		local file = t.file or -1
		local offset = t.offset or 0
		local ret = C.mmap(t.addr, size, access, bit.bor(MAP_PRIVATE, MAP_ANON), file, offset)
		if ffi.cast('intptr_t', ret) == ffi.cast('intptr_t', -1) then
			error(string.format('mmap errno: %d', ffi.errno()))
		end
		return checkh(ret)
	end

	function protect(addr, size)
		checkz(C.mprotect(addr, size, bit.bor(PROT_READ, PROT_EXEC)))
	end

	function free(addr, size)
		checkz(C.munmap(addr, size))
	end

	--[[
	function mmap.mirrors(size, times)

		local times = times or 2
		local size = mmap.aligned_size(size)

		local chosen_path
		local function mkstemp(path)
			local fd = C.mkstemp(path)
			if fd < 0 then return end
			chosen_path = path
			return fd
		end

		local shm_path = '/dev/shm/soundio-XXXXXX'
		local tmp_path = '/tmp/soundio-XXXXXX'

		local fd = mkstemp(shm_path) or mkstemp(tmp_path)

		if unlink(chosen_path) ~= 0 then
			close(fd)
			return
		end

		if ftruncate(fd, actual_size) ~= 0 then
			close(fd)
			return
		end

		local addr = mmap(nil, actual_size * 2, PROT_NONE,
			bit.bor(MAP_ANONYMOUS, MAP_PRIVATE), -1, 0)

		if addr == MAP_FAILED then
			return
		end

		local other_addr = mmap(addr, actual_size,
			bit.bor(PROT_READ, PROT_WRITE), bit.bor(MAP_FIXED, MAP_SHARED), fd, 0)

		if other_addr ~= addr then
			munmap(addr, 2 * actual_size)
			close(fd)
			return
		end

		local other_addr = mmap(addr + actual_size, actual_size,
			bit.bor(PROT_READ, PROT_WRITE), bit.bor(MAP_FIXED, MAP_SHARED), fd, 0)

		if other_addr ~= addr + actual_size then
			munmap(addr, 2 * actual_size)
			close(fd)
			return
		end

		if close(fd) ~= 0 then
			return
		end

		local function free()
			munmap(addr, 2 * actual_size)
		end

		ffi.gc(addr, free)

		return addr
	end
	]]

else
	error'platform not supported'
end

function mmap.mirror(t)
	local t = t or {}
	local size = t.size or mmap.pagesize()
	local times = t.times or 2
	local size = mmap.aligned_size(size)
	local access = 'w'
	assert(t.path or t.fileno, 'path or fileno missing')
	assert(times > 0, 'times must be > 0')

	local retries = -1
	local max_retries = t.max_retries or 100
	::try_again::
	retries = retries + 1
	if retries > max_retries then
		return nil, 'maximum retries reached', 'max_retries'
	end

	--try to allocate a contiguous block
	local map, errmsg, errcode = mmap.map{
		path = t.path, fileno = t.fileno,
		size = size * times,
		access = access,
		addr = t.addr}
	if not map then return nil, errmsg, errcode end

	--now free it so we can allocate it again in chunks all pointing at
	--the same offset 0 in the file, thus mirroring the same data.
	local maps = {}
	maps.addr = map.addr
	maps.size = size
	map:free()

	local addr = ffi.cast('char*', maps.addr)

	function maps:free()
		for _,map in ipairs(self) do
			map:free()
		end
	end

	for i = 1, times do
		local map1, errmsg, errcode = mmap.map{
			path = t.path, fileno = t.fileno,
			size = size,
			addr = addr + (i - 1) * size,
			access = access}
		if not map1 then
			maps:free()
			goto try_again
		end
		maps[i] = map1
	end

	return maps
end


--demo

if not ... then

	local function test_written(map)
		local p = ffi.cast('int32_t*', map.addr)
		for i = 0, map.size/4-1 do
			assert(p[i] == i)
		end
	end

	local function test_write(map)
		local p = ffi.cast('int32_t*', map.addr)
		for i = 0, map.size/4-1 do
			p[i] = i
		end
		test_written(map)
	end

	local function map_invalid_size()
		local ok, err = pcall(mmap.map, {path = 'mmap.lua', size = 0})
		assert(not ok and err:find'size')
	end

	local function map_invalid_offset()
		local ok, err = pcall(mmap.map, {path = 'mmap.lua', offset = 1})
		assert(not ok and err:find'aligned')
	end

	local function map_swap()
		local map = assert(mmap.map{access = 'w', size = 1000})
		print(map.addr, map.size)
		test_write(map)
		map:free()
	end

	local function map_swap_too_short()
		local map, errmsg, errcode = mmap.map{access = 'w', size = 1024^4}
		assert(not map and errcode == 'file_too_short')
	end

	--TODO: this test only works on 32bit and if the swapfile is > 3G.
	local function map_swap_out_of_mem()
		if not ffi.abi'32bit' then return end
		local map, errmsg, errcode = mmap.map{access = 'w', size = 2^30*3}
		assert(not map and errcode == 'out_of_mem')
	end

	local function map_file_readonly()
		local map = assert(mmap.map{path = 'mmap.lua'})
		print(map.addr, map.size)
		assert(ffi.string(map.addr, 20):find'--memory mapping')
		map:free()
	end

	local function map_file_readonly_not_found()
		local map, errmsg, errcode = mmap.map{path = 'askdfask8920349zjk'}
		assert(not map and errcode == 'not_found')
	end

	local function map_file_readonly_too_short()
		local map, errmsg, errcode = mmap.map{path = 'mmap.lua', size = 1024*100}
		assert(not map and errcode == 'file_too_short')
	end

	local function map_file_readonly_too_short_zero()
		local map, errmsg, errcode = mmap.map{path = 'media/zerosize'}
		assert(not map and errcode == 'file_too_short')
	end

	local function map_file_write_too_short_zero()
		local map, errmsg, errcode = mmap.map{path = 'media/zerosize', access = 'w'}
		assert(not map and errcode == 'file_too_short')
	end

	local function map_file_exec()
		local map = assert(mmap.map{path = 'bin/mingw64/luajit.exe', access = 'x'})
		print(map.addr, map.size)
		assert(ffi.string(map.addr, 2) == 'MZ')
		map:free()
	end

	local function map_file_write()
		local map = assert(mmap.map{path = 'mmap.tmp', size = 1000, access = 'w'})
		print(map.addr, map.size)
		test_write(map)
		map:free()
	end

	local function map_file_copy_on_write()
		map_file_write()
		local map = assert(mmap.map{path = 'mmap.tmp', size = 1000, access = 'c'})
		print(map.addr, map.size)
		ffi.fill(map.addr, map.size, 123)
		map:free()
		--check that the file wasn't altered by fill()
		local map = assert(mmap.map{path = 'mmap.tmp', size = 1000})
		test_written(map)
		map:free()
	end

	local function map_file_write_disk_full()
		local map, errmsg, errcode = mmap.map{path = 'mmap.tmp', size = 1024^4, access = 'w'}
		assert(not map and errcode == 'disk_full')
	end

	local function map_file_write_same_name()
		do return end
		local map1 = assert(mmap.map{name = 'mmap_test', path = 'mmap.tmp', access = 'w', size = 1000})
		local map2 = assert(mmap.map{name = 'mmap_test', path = 'mmap.tmp', access = 'w', size = 256})
		assert(map1.addr ~= map2.addr)
		for i = 0, 255 do
			ffi.cast('char*', map1.addr)[0] = i
		end
		map1:flush()
		map2:flush()
		for i = 0, 255 do
			assert(ffi.cast('char*', map2.addr)[0] == i)
		end
		map1:free()
		map2:free()
	end

	local function map_file_write_offset()
		local path = 'mmap-offset.tmp'
		local offset = mmap.pagesize()
		local map = assert(mmap.map{path = path, size = offset * 2, offset = 0, access = 'w'})
		print(map.addr, map.size)
		local p = ffi.cast('char*', map.addr)
		p[offset + 0] = 123
		p[offset + 1] = -123
		map:free()
		local map = assert(mmap.map{path = path, offset = offset, access = 'w'})
		print(map.addr, map.size)
		local p = ffi.cast('char*', map.addr)
		assert(p[0] == 123)
		assert(p[1] == -123)
		map:free()
	end

	local function map_file_mirror()
		local times = 50
		local map = assert(mmap.mirror{path = 'mmap-mirror.tmp', times = times})
		print(map.addr, map.size)
		local addr = map.addr
		local p = ffi.cast('char*', addr)
		p[0] = 123
		for i = 1, times-1 do
			assert(p[i*map.size] == 123)
		end
		map:free()
	end

	map_invalid_size()
	map_invalid_offset()

	map_swap()
	map_swap_too_short()
	map_swap_out_of_mem()
	map_file_readonly()
	map_file_readonly_not_found()
	map_file_readonly_too_short()
	map_file_readonly_too_short_zero()
	map_file_write_too_short_zero()
	map_file_exec()
	map_file_write()
	map_file_copy_on_write()
	map_file_write_disk_full()
	map_file_write_same_name()
	map_file_write_offset()
	map_file_mirror()

end

return mmap
