import Foundation

/// Minimal blocking POSIX Unix-domain socket helpers shared by the app and `th-hook`.
public enum UnixSocket {
    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    public static func connect(path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    /// Binds and listens, replacing a stale socket file.
    public static func listen(path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else { close(fd); return nil }
        chmod(path, 0o600)
        return fd
    }

    public static func accept(fd: Int32) -> Int32? {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return client
    }

    @discardableResult
    public static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Reads one newline-terminated line (without the newline). Nil on EOF before a newline.
    public static func readLine(fd: Int32, limit: Int = 4 << 20) -> Data? {
        var result = Data()
        var byte: UInt8 = 0
        while result.count < limit {
            let n = read(fd, &byte, 1)
            if n <= 0 { return nil }
            if byte == 0x0A { return result }
            result.append(byte)
        }
        return nil
    }

    public static func readToEOF(fd: Int32) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { return nil }
            if n == 0 { return result }
            result.append(contentsOf: buffer[0..<n])
        }
    }
}
