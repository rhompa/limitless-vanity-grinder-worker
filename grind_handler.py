"""
Wraps SolVanityCL subprocess for vanity address grinding.

Calls: python3 /app/main.py search-pubkey --starts-with|--ends-with <pattern>
       --count 1 --is-case-sensitive True --output-dir <tmpdir>

Output: <pubkey>.json files containing 64-byte Solana keypair arrays.
"""

import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


def grind_keypair(
    pattern: str,
    flag: str,
    max_seconds: int,
    request_id: str,
) -> tuple[str, bytes, float]:
    """
    Run SolVanityCL to grind a single keypair.

    Args:
        pattern: The vanity string (e.g. "DOGE")
        flag: "--starts-with" or "--ends-with"
        max_seconds: Timeout in seconds
        request_id: Unique request identifier (used for temp dir)

    Returns:
        (pubkey, keypair_bytes, elapsed_seconds)

    Raises:
        RuntimeError: If grind fails or times out
    """
    output_dir = tempfile.mkdtemp(prefix=f"grind-{request_id}-")

    try:
        cmd = [
            "python3",
            "/app/main.py",
            "search-pubkey",
            flag,
            pattern,
            "--count",
            "1",
            "--is-case-sensitive",
            "True",
            "--output-dir",
            output_dir,
        ]

        start = time.monotonic()

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=max_seconds,
            cwd="/app",
        )

        elapsed = time.monotonic() - start

        if result.returncode != 0:
            raise RuntimeError(
                f"SolVanityCL failed (exit {result.returncode}): "
                f"stdout={result.stdout[:500]}, stderr={result.stderr[:500]}"
            )

        # Find the output keypair file
        keypair_files = list(Path(output_dir).glob("*.json"))
        if not keypair_files:
            raise RuntimeError(
                f"No keypair files found in {output_dir}. "
                f"stdout={result.stdout[:500]}, stderr={result.stderr[:500]}"
            )

        keypair_file = keypair_files[0]
        pubkey = keypair_file.stem  # filename without .json extension

        # Verify the pubkey matches the pattern
        if flag == "--starts-with" and not pubkey.startswith(pattern):
            raise RuntimeError(
                f"Pubkey {pubkey} does not start with {pattern}"
            )
        if flag == "--ends-with" and not pubkey.endswith(pattern):
            raise RuntimeError(
                f"Pubkey {pubkey} does not end with {pattern}"
            )

        # Read keypair bytes
        with open(keypair_file, "r") as f:
            keypair_array = json.load(f)

        if not isinstance(keypair_array, list) or len(keypair_array) != 64:
            raise RuntimeError(
                f"Invalid keypair format: expected 64-byte array, "
                f"got {type(keypair_array).__name__} of length {len(keypair_array) if isinstance(keypair_array, list) else 'N/A'}"
            )

        keypair_bytes = bytes(keypair_array)

        return pubkey, keypair_bytes, elapsed

    except subprocess.TimeoutExpired:
        raise RuntimeError(
            f"Grind timed out after {max_seconds}s for pattern {pattern}"
        )

    finally:
        # Clean up temp directory
        shutil.rmtree(output_dir, ignore_errors=True)
