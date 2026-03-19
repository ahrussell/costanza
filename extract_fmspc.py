#!/usr/bin/env python3
"""Extract FMSPC from a TDX V4 DCAP quote's embedded PCK certificate."""

import sys
import struct
from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding


def extract_fmspc(quote_hex_path: str) -> str:
    # Read hex-encoded quote
    with open(quote_hex_path, "r") as f:
        hex_data = f.read().strip()

    raw = bytes.fromhex(hex_data)
    print(f"Quote size: {len(raw)} bytes")

    # Parse header
    version = struct.unpack_from("<H", raw, 0)[0]
    att_key_type = struct.unpack_from("<H", raw, 2)[0]
    tee_type = struct.unpack_from("<I", raw, 4)[0]
    print(f"Version: {version}, Att Key Type: {att_key_type}, TEE Type: 0x{tee_type:x}")

    if version != 4:
        print(f"WARNING: Expected version 4, got {version}")

    # Header is 48 bytes
    # TD Report Body is 584 bytes for TDX
    header_size = 48
    td_report_size = 584
    body_end = header_size + td_report_size

    print(f"Header: 0-{header_size}, TD Report Body: {header_size}-{body_end}")

    # After the body: signature data length (4 bytes)
    sig_data_len = struct.unpack_from("<I", raw, body_end)[0]
    print(f"Signature data length: {sig_data_len}")

    sig_data_start = body_end + 4
    sig_data = raw[sig_data_start:sig_data_start + sig_data_len]

    # Within signature data:
    # - ECDSA signature: 64 bytes
    # - ECDSA public key: 64 bytes
    # - Certification data type: 2 bytes
    # - Certification data size: 4 bytes
    # - Certification data: variable

    offset = 0
    ecdsa_sig = sig_data[offset:offset + 64]
    offset += 64
    ecdsa_pubkey = sig_data[offset:offset + 64]
    offset += 64

    cert_data_type = struct.unpack_from("<H", sig_data, offset)[0]
    offset += 2
    cert_data_size = struct.unpack_from("<I", sig_data, offset)[0]
    offset += 4

    print(f"Certification data type: {cert_data_type}, size: {cert_data_size}")

    cert_data = sig_data[offset:offset + cert_data_size]

    if cert_data_type == 5:
        # Type 5: PCK cert chain in PEM format (concatenated)
        pem_data = cert_data
        print(f"PCK cert chain (PEM), {len(pem_data)} bytes")

        # Parse PEM certificates - find all BEGIN/END CERTIFICATE blocks
        pem_str = pem_data.decode("ascii", errors="replace")
        certs = []
        start = 0
        while True:
            begin = pem_str.find("-----BEGIN CERTIFICATE-----", start)
            if begin == -1:
                break
            end = pem_str.find("-----END CERTIFICATE-----", begin)
            if end == -1:
                break
            end += len("-----END CERTIFICATE-----")
            cert_pem = pem_str[begin:end].encode()
            certs.append(x509.load_pem_x509_certificate(cert_pem))
            start = end

        print(f"Found {len(certs)} certificates in chain")

        if not certs:
            raise ValueError("No certificates found in cert chain")

        # The first cert is the PCK leaf certificate
        pck_cert = certs[0]
        print(f"PCK cert subject: {pck_cert.subject}")
        print(f"PCK cert issuer: {pck_cert.issuer}")

        # Look for SGX Extensions OID: 1.2.840.113741.1.13.1
        sgx_extensions_oid = x509.ObjectIdentifier("1.2.840.113741.1.13.1")
        fmspc_oid = x509.ObjectIdentifier("1.2.840.113741.1.13.1.4")

        for ext in pck_cert.extensions:
            print(f"  Extension OID: {ext.oid.dotted_string}")
            if ext.oid == sgx_extensions_oid:
                print(f"  Found SGX Extensions!")
                # The SGX extensions is an ASN.1 SEQUENCE of OID-value pairs
                # Parse it manually from the raw DER value
                sgx_ext_value = ext.value.value
                fmspc = parse_sgx_extensions_for_fmspc(sgx_ext_value)
                if fmspc:
                    return fmspc

    elif cert_data_type == 6:
        # Type 6: QE Report Certification Data contains nested cert data
        # Parse the nested structure
        print("Type 6: nested certification data")
        # QE Report (384 bytes) + QE Report Signature (64 bytes) + QE Auth Data (2+var) + QE Cert Data
        qe_report = cert_data[0:384]
        qe_report_sig = cert_data[384:448]
        qe_auth_len = struct.unpack_from("<H", cert_data, 448)[0]
        qe_auth = cert_data[450:450 + qe_auth_len]
        nested_offset = 450 + qe_auth_len
        nested_cert_type = struct.unpack_from("<H", cert_data, nested_offset)[0]
        nested_cert_size = struct.unpack_from("<I", cert_data, nested_offset + 2)[0]
        nested_cert_data = cert_data[nested_offset + 6:nested_offset + 6 + nested_cert_size]
        print(f"  Nested cert type: {nested_cert_type}, size: {nested_cert_size}")

        if nested_cert_type == 5:
            pem_str = nested_cert_data.decode("ascii", errors="replace")
            certs = []
            start = 0
            while True:
                begin = pem_str.find("-----BEGIN CERTIFICATE-----", start)
                if begin == -1:
                    break
                end = pem_str.find("-----END CERTIFICATE-----", begin)
                if end == -1:
                    break
                end += len("-----END CERTIFICATE-----")
                cert_pem = pem_str[begin:end].encode()
                certs.append(x509.load_pem_x509_certificate(cert_pem))
                start = end

            print(f"  Found {len(certs)} certificates in nested chain")
            if certs:
                pck_cert = certs[0]
                print(f"  PCK cert subject: {pck_cert.subject}")
                sgx_extensions_oid = x509.ObjectIdentifier("1.2.840.113741.1.13.1")
                for ext in pck_cert.extensions:
                    if ext.oid == sgx_extensions_oid:
                        print(f"  Found SGX Extensions!")
                        sgx_ext_value = ext.value.value
                        fmspc = parse_sgx_extensions_for_fmspc(sgx_ext_value)
                        if fmspc:
                            return fmspc

    raise ValueError("Could not find FMSPC in quote")


def parse_sgx_extensions_for_fmspc(der_bytes: bytes) -> str:
    """Parse the SGX Extensions ASN.1 structure to find the FMSPC value.

    The SGX Extensions is a SEQUENCE of SEQUENCEs, each containing:
      - OID (the sub-extension identifier)
      - Value (OCTET STRING or nested structure)

    FMSPC OID: 1.2.840.113741.1.13.1.4
    """
    from cryptography.hazmat.primitives.serialization import Encoding

    # Use a simple ASN.1 DER parser
    fmspc_oid_der = encode_oid("1.2.840.113741.1.13.1.4")

    # Search for the FMSPC OID in the DER bytes
    idx = der_bytes.find(fmspc_oid_der)
    if idx == -1:
        print("  FMSPC OID not found in SGX extensions DER")
        # Try to dump all OIDs found
        dump_asn1_oids(der_bytes)
        return None

    print(f"  Found FMSPC OID at offset {idx}")

    # After the OID, there should be an OCTET STRING with the FMSPC value
    # Skip the OID
    after_oid = idx + len(fmspc_oid_der)

    # Parse the next TLV (should be OCTET STRING tag 0x04)
    tag = der_bytes[after_oid]
    length = der_bytes[after_oid + 1]

    if tag == 0x04:  # OCTET STRING
        fmspc_bytes = der_bytes[after_oid + 2:after_oid + 2 + length]
        fmspc_hex = fmspc_bytes.hex()
        print(f"  FMSPC (OCTET STRING): {fmspc_hex}")
        return fmspc_hex
    elif tag == 0x30:  # SEQUENCE - might be wrapped
        # Look inside
        inner = der_bytes[after_oid + 2:after_oid + 2 + length]
        if inner[0] == 0x04:
            inner_len = inner[1]
            fmspc_bytes = inner[2:2 + inner_len]
            fmspc_hex = fmspc_bytes.hex()
            print(f"  FMSPC (wrapped OCTET STRING): {fmspc_hex}")
            return fmspc_hex

    # Fallback: scan for 6-byte value after OID
    print(f"  Tag after OID: 0x{tag:02x}, length: {length}")
    # Try reading 6 bytes after TLV header
    fmspc_bytes = der_bytes[after_oid + 2:after_oid + 2 + 6]
    fmspc_hex = fmspc_bytes.hex()
    print(f"  FMSPC (fallback 6 bytes): {fmspc_hex}")
    return fmspc_hex


def encode_oid(oid_str: str) -> bytes:
    """Encode an OID string to DER format (just the value, no tag/length)."""
    parts = [int(p) for p in oid_str.split(".")]

    # First two components encoded as 40*X + Y
    encoded = [40 * parts[0] + parts[1]]

    for part in parts[2:]:
        if part < 128:
            encoded.append(part)
        else:
            # Base-128 encoding
            octets = []
            val = part
            while val > 0:
                octets.append(val & 0x7f)
                val >>= 7
            octets.reverse()
            for i in range(len(octets) - 1):
                octets[i] |= 0x80
            encoded.extend(octets)

    # Return with OID tag (0x06) and length
    value = bytes(encoded)
    return bytes([0x06, len(value)]) + value


def dump_asn1_oids(der_bytes: bytes):
    """Debug helper: find all OID tags in DER bytes."""
    i = 0
    while i < len(der_bytes) - 2:
        if der_bytes[i] == 0x06:  # OID tag
            oid_len = der_bytes[i + 1]
            if oid_len > 0 and i + 2 + oid_len <= len(der_bytes):
                oid_bytes = der_bytes[i + 2:i + 2 + oid_len]
                try:
                    oid_str = decode_oid(oid_bytes)
                    print(f"    OID at {i}: {oid_str}")
                except:
                    pass
            i += 2 + oid_len
        else:
            i += 1


def decode_oid(oid_bytes: bytes) -> str:
    """Decode DER OID value bytes to dotted string."""
    if not oid_bytes:
        return ""

    parts = [oid_bytes[0] // 40, oid_bytes[0] % 40]

    i = 1
    while i < len(oid_bytes):
        val = 0
        while i < len(oid_bytes):
            byte = oid_bytes[i]
            val = (val << 7) | (byte & 0x7f)
            i += 1
            if not (byte & 0x80):
                break
        parts.append(val)

    return ".".join(str(p) for p in parts)


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "gcp_quote.hex"
    fmspc = extract_fmspc(path)
    print(f"\n=== FMSPC: {fmspc} ===")
