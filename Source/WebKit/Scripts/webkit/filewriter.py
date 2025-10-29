# Copyright (C) 2025 Apple Inc. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1.  Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
# 2.  Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


class FileWriterIfChanged:
    """A file-like object that only writes to disk if the content has changed.

    This context manager accumulates all writes in memory, then upon exit compares
    the accumulated content to the existing file content. It only writes to disk
    if the content differs, preserving file timestamps when content is unchanged.

    Usage:
        with FileWriterIfChanged('output.txt') as f:
            f.write('content')
    """

    def __init__(self, filepath):
        self.filepath = filepath
        self.content = []

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is not None:
            # Don't write anything if an exception occurred
            return False

        new_content = ''.join(self.content)

        # Read existing file content if it exists
        try:
            with open(self.filepath, 'r') as f:
                existing_content = f.read()
        except FileNotFoundError:
            existing_content = None

        # Only write if content has changed
        if existing_content != new_content:
            with open(self.filepath, 'w') as f:
                f.write(new_content)

        return False

    def write(self, data):
        """Accumulate write data in memory."""
        self.content.append(data)
