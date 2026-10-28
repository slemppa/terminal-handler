import Darwin

/// Walks up the process tree from `pid` and returns the first ancestor that
/// has a controlling terminal. Hooks themselves run without one, but the
/// `claude` process that spawned them sits on the Ghostty terminal's TTY.
public func controllingTTY(startingAt pid: pid_t, maxDepth: Int = 6) -> (tty: String, pid: pid_t)? {
    var current = pid
    for _ in 0..<maxDepth {
        guard current > 1, let info = kinfo(for: current) else { return nil }
        let dev = info.kp_eproc.e_tdev
        if dev != dev_t.max, let name = devname(dev, S_IFCHR) {
            return (String(cString: name), current)
        }
        current = info.kp_eproc.e_ppid
    }
    return nil
}

private func kinfo(for pid: pid_t) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
}
