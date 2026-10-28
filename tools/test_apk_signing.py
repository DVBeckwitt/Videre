"""Regression fixtures for Windows and Linux apksigner certificate output."""

import pathlib
import subprocess
import sys
import unittest


EXPECTED = "e6f70a6eafad31f11a8d19eaf2458f4dbcbcf1944ea1699ef0598e008af7b3f5"
WRONG_TEST_KEY = "b56ab7d577678f30ca7b70c0419b6753cd780f3838cabff1dc5c64f4d9cc81eb"
SCRIPT = pathlib.Path(__file__).with_name("verify_apk_signing.py")
WINDOWS_CERTIFICATE = "Signer #1 certificate SHA-256 digest: " + EXPECTED
LINUX_CERTIFICATE = "V2 Signer: certificate SHA-256 digest: " + EXPECTED


class VerifyApkSigningTest(unittest.TestCase):
    def invoke(self, output, *arguments):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            input=output,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def verify(self, output, code=0, expected=EXPECTED):
        result = self.invoke(output, expected)
        self.assertEqual(result.returncode, code, result.stderr)
        return result

    def test_recorded_windows_label_with_normal_metadata(self):
        self.verify(
            "Verifies\nVerified using v2 scheme (APK Signature Scheme v2): true\n"
            "Number of signers: 1\nSigner #1 certificate DN: CN=Videre\n"
            + WINDOWS_CERTIFICATE
            + "\nSigner #1 certificate SHA-1 digest: other-metadata\n"
            "Signer #1 public key SHA-256 digest: "
            + WRONG_TEST_KEY
            + "\n"
        )

    def test_recorded_linux_label(self):
        self.verify(LINUX_CERTIFICATE + "\n")

    def test_versioned_linux_labels_and_repeated_same_certificate(self):
        self.verify(
            "\n".join(
                label + EXPECTED
                for label in (
                    "V1 Signer: certificate SHA-256 digest: ",
                    "V2 Signer: certificate SHA-256 digest: ",
                    "V3 Signer: certificate SHA-256 digest: ",
                    "V3.1 Signer: certificate SHA-256 digest: ",
                    "V4 Signer: certificate SHA-256 digest: ",
                )
            )
        )

    def test_repeated_windows_signers_with_same_certificate(self):
        self.verify(WINDOWS_CERTIFICATE + "\nSigner #2 certificate SHA-256 digest: " + EXPECTED)

    def test_uppercase_hex_and_crlf_are_accepted(self):
        self.verify(
            "Signer #1 certificate SHA-256 digest: " + EXPECTED.upper() + "\r\n",
            expected=EXPECTED.upper(),
        )

    def test_source_stamp_does_not_change_actual_signer_pin(self):
        self.verify(
            WINDOWS_CERTIFICATE
            + "\nSource Stamp Signer certificate SHA-256 digest: "
            + WRONG_TEST_KEY
            + "\n"
        )

    def test_wrong_signer_and_mixed_signers_fail(self):
        for output in (
            "Signer #1 certificate SHA-256 digest: " + WRONG_TEST_KEY,
            "V2 Signer: certificate SHA-256 digest: " + WRONG_TEST_KEY,
            WINDOWS_CERTIFICATE + "\nSigner #2 certificate SHA-256 digest: " + WRONG_TEST_KEY,
            LINUX_CERTIFICATE + "\nV3.1 Signer: certificate SHA-256 digest: " + WRONG_TEST_KEY,
        ):
            with self.subTest(output=output):
                self.verify(output, 1)

    def test_missing_signer_certificate_fails(self):
        for output in (
            "",
            "Verifies\nNumber of signers: 1\n",
            "Signer #1 certificate DN: CN=Videre\nSigner #1 certificate SHA-1 digest: metadata\n",
            "Signer #1 public key SHA-256 digest: " + EXPECTED,
            "Source Stamp Signer certificate SHA-256 digest: " + EXPECTED,
            "Source Stamp Signer certificate SHA-256 digest: " + WRONG_TEST_KEY,
            "Source Stamp Signer: certificate SHA-256 digest: " + EXPECTED,
        ):
            with self.subTest(output=output):
                self.verify(output, 1)

    def test_malformed_or_unrecognized_certificate_field_fails_even_after_valid_signer(self):
        for field in (
            "Signer #1 certificate SHA-256 digest: ",
            "Signer #1 certificate SHA-256 digest: " + EXPECTED[:-1],
            "Signer #1 certificate SHA-256 digest: " + EXPECTED + "0",
            "Signer #1 certificate SHA-256 digest: " + EXPECTED[:-1] + "g",
            "Signer #1 certificate SHA-256 digest: " + EXPECTED + " extra",
            "Signer #1 certificate SHA-256 digest " + EXPECTED,
            "Signer #1 certificate SHA256 digest: " + EXPECTED,
            "Signer #0 certificate SHA-256 digest: " + EXPECTED,
            "Unknown Signer certificate SHA-256 digest: " + EXPECTED,
            "V5 Signer: certificate SHA-256 digest: " + EXPECTED,
            "Source Stamp Signer certificate SHA-256 digest: malformed",
        ):
            for prefix in ("", WINDOWS_CERTIFICATE + "\n"):
                with self.subTest(field=field, has_valid_prefix=bool(prefix)):
                    self.verify(prefix + field, 1)

    def test_malformed_expected_argument_returns_usage_error(self):
        for arguments in (
            (),
            (EXPECTED, EXPECTED),
            ("",),
            (EXPECTED[:-1],),
            (EXPECTED + "0",),
            (EXPECTED[:-1] + "g",),
            (" " + EXPECTED,),
            (EXPECTED + "\n",),
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.invoke(WINDOWS_CERTIFICATE, *arguments).returncode, 64)


if __name__ == "__main__":
    unittest.main()
