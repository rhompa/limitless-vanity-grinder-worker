"""
AES-256-GCM encryption for keypair transport security.

The worker encrypts keypairs before sending over HTTP.
The backend decrypts using the same shared key.
"""

import base64
import json
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def encrypt_keypair(keypair_bytes: bytes, hex_key: str) -> tuple[str, str, str]:
    """
    Encrypt a 64-byte Solana keypair with AES-256-GCM.

    Args:
        keypair_bytes: Raw 64-byte keypair
        hex_key: 32-byte key as hex string (64 hex chars)

    Returns:
        (ciphertext_b64, iv_b64, tag_b64)
        - ciphertext_b64: base64-encoded ciphertext (without tag)
        - iv_b64: base64-encoded 12-byte IV/nonce
        - tag_b64: base64-encoded 16-byte auth tag
    """
    key = bytes.fromhex(hex_key)
    iv = os.urandom(12)
    aesgcm = AESGCM(key)

    # Serialize keypair as JSON array (matches Solana keypair format)
    plaintext = json.dumps(list(keypair_bytes)).encode("utf-8")

    # AESGCM.encrypt returns ciphertext + tag (last 16 bytes)
    ct_with_tag = aesgcm.encrypt(iv, plaintext, None)
    ciphertext = ct_with_tag[:-16]
    tag = ct_with_tag[-16:]

    return (
        base64.b64encode(ciphertext).decode("ascii"),
        base64.b64encode(iv).decode("ascii"),
        base64.b64encode(tag).decode("ascii"),
    )


def decrypt_keypair(ciphertext_b64: str, iv_b64: str, tag_b64: str, hex_key: str) -> bytes:
    """
    Decrypt an AES-256-GCM encrypted keypair.

    Args:
        ciphertext_b64: base64-encoded ciphertext
        iv_b64: base64-encoded 12-byte IV
        tag_b64: base64-encoded 16-byte auth tag
        hex_key: 32-byte key as hex string

    Returns:
        Raw 64-byte keypair as bytes
    """
    key = bytes.fromhex(hex_key)
    iv = base64.b64decode(iv_b64)
    ciphertext = base64.b64decode(ciphertext_b64)
    tag = base64.b64decode(tag_b64)

    aesgcm = AESGCM(key)
    plaintext = aesgcm.decrypt(iv, ciphertext + tag, None)

    keypair_array = json.loads(plaintext.decode("utf-8"))
    return bytes(keypair_array)
