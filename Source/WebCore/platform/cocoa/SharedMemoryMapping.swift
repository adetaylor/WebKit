// Copyright (C) 2010-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT

public import Darwin
import os
import wtf.SPI.cocoa.MachVMSPI

private let logger = Logger(subsystem: "com.apple.WebKit", category: "VirtualMemory")

/// Memory that another process shares, mapped into this one, read-only or read-write, until this goes, as
/// WebCore::SharedMemory::map() maps a handle's memory entry (SharedMemoryCocoa.mm).
///
/// Its bytes stay at the same address for as long as it exists. The other process can change them at any time, so only
/// code that reads them as such (atomically, or copying them once) may use them.
@_spi(WebKitGPU)
public final class SharedMemoryMapping: Sendable {
    let address: mach_vm_address_t
    public let size: UInt64
    public let isWritable: Bool

    /// Maps the size bytes of the memory entry that port names. The caller keeps its own right to the port, which the
    /// mapping doesn't need once it exists. nil if they can't be mapped.
    ///
    /// The caller promises that the port is the right to a memory entry that a handle it owns carries (as
    /// IPCTypes.SharedMemoryHandle's port), not the name of some other entry of this process.
    @unsafe
    public init?(port: mach_port_t, size: UInt64, writable: Bool) {
        guard size > 0 else {
            return nil
        }
        let protection = writable ? VM_PROT_READ | VM_PROT_WRITE : VM_PROT_READ
        var mappedAddress: mach_vm_address_t = 0
        // Safety: mach_task_self_ is set before any Swift code runs, and never changes. mach_vm_map() only writes the
        // address, before it returns.
        let result = unsafe mach_vm_map(
            mach_task_self_,
            &mappedAddress,
            size,
            0,
            VM_FLAGS_ANYWHERE | VM_FLAGS_RETURN_DATA_ADDR,
            port,
            0,
            0,
            protection,
            protection,
            VM_INHERIT_NONE
        )
        guard result == KERN_SUCCESS, mappedAddress != 0 else {
            logger.error("SharedMemory::map: Failed to map shared memory. (\(result))")
            return nil
        }
        address = mappedAddress
        self.size = size
        isWritable = writable
    }

    deinit {
        // Safety: as in init.
        let result = unsafe mach_vm_deallocate(mach_task_self_, address, size)
        if result != KERN_SUCCESS {
            logger.error("SharedMemory::~SharedMemory: Failed to deallocate shared memory. (\(result))")
            assertionFailure()
        }
    }
}

#endif // ENABLE_WEBCORE_SWIFT
