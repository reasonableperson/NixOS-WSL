# Binary stdin/stdout carry SSH-agent frames; diagnostics must stay on stderr.
$ErrorActionPreference = 'Stop'

function Read-Message($stream) {
    $header = [byte[]]::new(4)
    $offset = 0
    while ($offset -lt 4) {
        $n = $stream.Read($header, $offset, 4 - $offset)
        if ($n -eq 0) {
            if ($offset -eq 0) { return $null }
            throw 'Truncated SSH-agent header'
        }
        $offset += $n
    }
    $length = (($header[0] * 256 + $header[1]) * 256 + $header[2]) * 256 + $header[3]
    if ($length -lt 1 -or $length -gt 262144) {
        throw 'Invalid SSH-agent message length'
    }
    $message = [byte[]]::new(4 + $length)
    [Array]::Copy($header, $message, 4)
    while ($offset -lt $message.Length) {
        $n = $stream.Read($message, $offset, $message.Length - $offset)
        if ($n -eq 0) { throw 'Truncated SSH-agent body' }
        $offset += $n
    }
    return ,$message
}

try {
    $stdin = [Console]::OpenStandardInput()
    $stdout = [Console]::OpenStandardOutput()
    while ($null -ne ($request = Read-Message $stdin)) {
        # Older Windows agents disconnect on OpenSSH extensions (e.g. session-bind).
        if ($request[4] -eq 27) {
            $response = [byte[]](0, 0, 0, 1, 6)
        } else {
            $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', 'openssh-ssh-agent', 'InOut')
            try {
                $pipe.Connect(5000)
                $pipe.Write($request, 0, $request.Length)
                $pipe.Flush()
                $response = Read-Message $pipe
                if ($null -eq $response) { throw 'Windows SSH agent disconnected' }
            } finally {
                $pipe.Dispose()
            }
        }
        $stdout.Write($response, 0, $response.Length)
        $stdout.Flush()
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
