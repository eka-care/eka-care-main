"""Acceptance tests for deploy.py's ask()/confirm_existing_config() gating.

The bug being guarded against: the original bash deploy-local.sh only
re-prompted an existing value when confirm_existing was set, so the
"review every field" (full reconfigure) flow silently skipped fields like
EXTERNAL_URL / SSL_MODE / CLIENT_NAME. The Python port fixes it with the
`(confirm_existing or state.reconfigure)` clause in ask() - so reconfigure
mode reviews EVERY field with a value, regardless of confirm_existing.

Run from the repo root:  python3 -m unittest tests.test_deploy_gating
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import deploy  # noqa: E402


def fresh_state(**values):
    st = deploy.State()
    st.values = dict(values)
    return st


class RecordingInput:
    """Stands in for builtins.input / getpass.getpass. Records every prompt it
    was shown and replies with a queue of answers ('' => Enter-to-keep)."""

    def __init__(self, answers=None):
        self.prompts = []
        self.answers = list(answers or [])

    def __call__(self, prompt=""):
        self.prompts.append(prompt)
        return self.answers.pop(0) if self.answers else ""


def call_ask(state, rec, **kw):
    with mock.patch("builtins.input", rec), mock.patch.object(deploy.getpass, "getpass", rec):
        return deploy.ask(state, kw.pop("prompt", "Some field"), kw.pop("varname", "SOME_FIELD"), **kw)


class AskGatingTests(unittest.TestCase):
    # --- THE bug acceptance test -------------------------------------------
    def test_reconfigure_reviews_even_confirm_existing_false_fields(self):
        """Full-review (reconfigure) must prompt a field with a value even when
        confirm_existing is False - this is exactly what bash was missing."""
        state = fresh_state(EXTERNAL_URL="emr.miracleshealth.com")
        state.reconfigure = True  # user declined "use as-is", named no fields
        rec = RecordingInput()  # Enter to keep
        result = call_ask(state, rec, varname="EXTERNAL_URL", confirm_existing=False)

        self.assertEqual(len(rec.prompts), 1, "reconfigure should have prompted the field")
        self.assertIn("Enter to keep", rec.prompts[0])
        self.assertIn("emr.miracleshealth.com", rec.prompts[0])
        self.assertEqual(result, "emr.miracleshealth.com", "blank Enter keeps the existing value")

    def test_reconfigure_accepts_a_new_value(self):
        state = fresh_state(SSL_MODE="external")
        state.reconfigure = True
        rec = RecordingInput(answers=["managed"])
        result = call_ask(state, rec, varname="SSL_MODE", confirm_existing=False)
        self.assertEqual(result, "managed")

    # --- use-as-is (config_confirmed) suppresses the walkthrough ------------
    def test_config_confirmed_skips_existing_values(self):
        state = fresh_state(CLIENT_NAME="metropolis")
        state.config_confirmed = True
        rec = RecordingInput()
        result = call_ask(state, rec, varname="CLIENT_NAME", confirm_existing=True)
        self.assertEqual(rec.prompts, [], "use-as-is must not re-prompt set values")
        self.assertEqual(result, "metropolis")

    # --- narrow selection: only named fields re-prompt ----------------------
    def test_fields_to_change_only_prompts_named_fields(self):
        state = fresh_state(EXTERNAL_URL="emr.miracleshealth.com", CLIENT_SECRET="oldsecret")
        state.reconfigure = True
        state.fields_to_change = ["CLIENT_SECRET"]

        rec_unnamed = RecordingInput()
        kept = call_ask(state, rec_unnamed, varname="EXTERNAL_URL", confirm_existing=True)
        self.assertEqual(rec_unnamed.prompts, [], "unnamed field must be kept silently")
        self.assertEqual(kept, "emr.miracleshealth.com")

        rec_named = RecordingInput(answers=["newsecret"])
        changed = call_ask(state, rec_named, varname="CLIENT_SECRET", secret=True, confirm_existing=True)
        self.assertEqual(len(rec_named.prompts), 1, "named field must be prompted")
        self.assertEqual(changed, "newsecret")

    # --- non-interactive never blocks on input ------------------------------
    def test_non_interactive_keeps_existing_without_prompting(self):
        state = fresh_state(PORT="7090")
        state.non_interactive = True
        rec = RecordingInput()
        result = call_ask(state, rec, varname="PORT", confirm_existing=True, required=True)
        self.assertEqual(rec.prompts, [])
        self.assertEqual(result, "7090")

    def test_non_interactive_blank_uses_default(self):
        state = fresh_state()
        state.non_interactive = True
        rec = RecordingInput()
        result = call_ask(state, rec, varname="SSL_MODE", default="external", required=True)
        self.assertEqual(result, "external")

    def test_non_interactive_blank_required_no_default_dies(self):
        state = fresh_state()
        state.non_interactive = True
        rec = RecordingInput()
        with self.assertRaises(SystemExit):
            call_ask(state, rec, varname="CLIENT_ID", required=True)

    # --- blank field falls through to a normal prompt -----------------------
    def test_blank_field_prompts_normally(self):
        state = fresh_state()  # APP_IMAGE unset
        rec = RecordingInput(answers=["ekacare/img:v1"])
        result = call_ask(state, rec, varname="APP_IMAGE")
        self.assertEqual(len(rec.prompts), 1)
        self.assertNotIn("Enter to keep", rec.prompts[0])
        self.assertEqual(result, "ekacare/img:v1")


class ConfirmExistingConfigTests(unittest.TestCase):
    def _state_with_config(self, contents):
        st = deploy.State()
        fd, path = tempfile.mkstemp(suffix=".env")
        os.close(fd)
        Path(path).write_text(contents)
        st.config_file = Path(path)
        st.values = deploy.load_env_file(st.config_file)
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return st

    def test_use_as_is_sets_config_confirmed(self):
        state = self._state_with_config("PORT=7090\nCLIENT_SECRET=abc\n")
        with mock.patch("builtins.input", RecordingInput(answers=["Y"])):
            deploy.confirm_existing_config(state)
        self.assertTrue(state.config_confirmed)
        self.assertFalse(state.reconfigure)
        self.assertEqual(state.fields_to_change, [])

    def test_decline_then_blank_is_full_review(self):
        state = self._state_with_config("PORT=7090\n")
        with mock.patch("builtins.input", RecordingInput(answers=["n", ""])):
            deploy.confirm_existing_config(state)
        self.assertTrue(state.reconfigure)
        self.assertFalse(state.config_confirmed)
        self.assertEqual(state.fields_to_change, [])

    def test_decline_then_named_fields_uppercased_and_split(self):
        state = self._state_with_config("PORT=7090\n")
        with mock.patch("builtins.input", RecordingInput(answers=["n", "client_secret, api_key"])):
            deploy.confirm_existing_config(state)
        self.assertTrue(state.reconfigure)
        self.assertEqual(state.fields_to_change, ["CLIENT_SECRET", "API_KEY"])


class FullReviewFlowTests(unittest.TestCase):
    """Drives the real value-collecting steps (bypassing the Linux-only
    preflight guard) to prove full-review actually reaches EXTERNAL_URL /
    SSL_MODE / CLIENT_NAME / APP_IMAGE / CLIENT_ID - the exact prompts the
    bash version skipped and this rewrite was written to restore."""

    def _reconfigure_state(self):
        st = deploy.State()
        fd, path = tempfile.mkstemp(suffix=".env")
        os.close(fd)
        # Real (non-placeholder) credentials so the keep-path accepts a blank
        # Enter; SSL_MODE=external skips the managed cert branch; a valid
        # CLIENT_NAME avoids the metropolis/miracles re-ask loop.
        Path(path).write_text(
            "PORT=7090\nEXTERNAL_URL=emr.miracleshealth.com\nAPP_IMAGE=\n"
            "SSL_MODE=external\nCLIENT_NAME=metropolis\n"
            "CLIENT_ID=cid-123\nCLIENT_SECRET=sec-123\nAPI_KEY=key-123\n"
            "SIGNING_KEY=abcdef\nYELLOW_AI_API_KEY=y\nJAPI_KEY=j\nJAPI_AUTHORIZATION=ja\n"
        )
        st.config_file = Path(path)
        st.values = deploy.load_env_file(st.config_file)
        st.reconfigure = True
        st.dry_run = True  # set_env_var prints, state_mark_done no-ops
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        return st

    def test_full_review_prompts_every_value_field(self):
        state = self._reconfigure_state()
        rec = RecordingInput()  # all Enter-to-keep
        with mock.patch("builtins.input", rec), mock.patch.object(deploy.getpass, "getpass", rec):
            deploy.step_ssl_setup(state)
            deploy.step_generate_env(state)
        joined = "\n".join(rec.prompts)
        for field in ("External URL", "Manage SSL", "Pre-built image",
                      "Client integration", "Client ID"):
            self.assertIn(field, joined, f"full review should have prompted for {field!r}")
        # blank Enter preserved the existing values
        self.assertEqual(state.values["EXTERNAL_URL"], "emr.miracleshealth.com")
        self.assertEqual(state.values["CLIENT_NAME"], "metropolis")


if __name__ == "__main__":
    unittest.main()
