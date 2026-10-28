"""Verify APK signer certificate fingerprints from apksigner --print-certs output."""

import re
import sys


_SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z", re.ASCII)
_SIGNER_CERTIFICATE = re.compile(
    r"(?:Signer #[1-9][0-9]* certificate|"
    r"V(?:1|2|3(?:\.1)?|4) Signer: certificate)"
    r" SHA-256 digest: ([0-9a-fA-F]{64})\Z",
    re.ASCII,
)
_SOURCE_STAMP_CERTIFICATE = re.compile(
    r"Source Stamp Signer:? certificate SHA-256 digest: [0-9a-fA-F]{64}\Z",
    re.ASCII,
)
_CERTIFICATE_SHA256_FIELD = re.compile(
    r"\bcertificate\s+SHA[\s-]*256\b", re.IGNORECASE | re.ASCII
)


def main():
    if len(sys.argv) != 2 or not _SHA256.fullmatch(sys.argv[1]):
        print("Usage: verify_apk_signing.py EXPECTED_SHA256", file=sys.stderr)
        return 64

    expected = sys.argv[1].lower()
    found = False
    try:
        for raw_line in sys.stdin:
            line = raw_line.strip()
            certificate = _SIGNER_CERTIFICATE.fullmatch(line)
            if certificate:
                found = True
                if certificate.group(1).lower() != expected:
                    print("APK signer certificate does not match the release pin.", file=sys.stderr)
                    return 1
            elif _SOURCE_STAMP_CERTIFICATE.fullmatch(line):
                # A source stamp is not the certificate Android uses for updates.
                continue
            elif _CERTIFICATE_SHA256_FIELD.search(line):
                print("Unrecognized APK certificate SHA-256 field.", file=sys.stderr)
                return 1
    except UnicodeError:
        print("Unable to decode apksigner output.", file=sys.stderr)
        return 1

    if not found:
        print("No APK signer certificate SHA-256 digest found.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
