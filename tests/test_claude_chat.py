"""End-to-end tests for bin/claude-chat on fake profiles in a temporary HOME.

Run: python3 -m unittest discover tests
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

TOOL = os.path.join(os.path.dirname(__file__), "..", "bin", "claude-chat")
APP = "/Applications/Claude.app/Contents/MacOS/Claude"


class Home:
    """A fake HOME with Claude profiles: the default one plus claude-multiprofile ones.

    `desktop_only` profiles have no Code half: their Code tab runs on the shared ~/.claude.
    """

    def __init__(self, extra=("work", "client"), desktop_only=()):
        self.root = tempfile.mkdtemp(prefix="claude-chat-test-")
        self.support = os.path.join(self.root, "Library/Application Support")
        self.profiles = {"default": (os.path.join(self.support, "Claude"), os.path.join(self.root, ".claude"))}
        reg = []
        for name in extra:
            data, cfg = os.path.join(self.support, f"Claude-{name}"), os.path.join(self.root, f".claude-{name}")
            self.profiles[name] = (data, cfg)
            reg.append({"name": name, "desktop": {"dataDir": data}, "code": {"configDir": cfg}})
        for name in desktop_only:
            data = os.path.join(self.support, f"Claude-{name}")
            self.profiles[name] = (data, self.profiles["default"][1])
            reg.append({"name": name, "type": "desktop", "desktop": {"dataDir": data}, "code": None})
        self.write(".config/claude-multiprofile/profiles.json", {"profiles": reg})
        for i, (name, (data, cfg)) in enumerate(self.profiles.items()):
            acct = f"acct-{name}"
            self.write_abs(os.path.join(data, "config.json"), {"lastKnownAccountUuid": acct})
            self.write_abs(os.path.join(data, "claude-code-sessions", acct, "org", "archived-sessions.idx"),
                           {"v": 1, "archived": []})
            if name in desktop_only:
                continue
            account_json = os.path.join(self.root, ".claude.json") if name == "default" else os.path.join(cfg, ".claude.json")
            self.write_abs(account_json, {"oauthAccount": {"accountUuid": acct, "emailAddress": f"{name}@example.com"}})
        self.open_apps = set()
        self.other_processes = []

    def write(self, rel, data):
        self.write_abs(os.path.join(self.root, rel), data)

    def write_abs(self, path, data):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(data if isinstance(data, str) else json.dumps(data))

    def sessions(self, name):
        return os.path.join(self.profiles[name][0], "claude-code-sessions", f"acct-{name}", "org")

    def transcript(self, name, cwd, cli):
        enc = "".join(c if c.isalnum() else "-" for c in cwd)
        return os.path.join(self.profiles[name][1], "projects", enc, cli + ".jsonl")

    def chat(self, name, sid, cli, title, text, cwd="/tmp/proj", parent=None, **extra):
        rec = {"sessionId": sid, "cliSessionId": cli, "cwd": cwd, "title": title, "lastActivityAt": 1, **extra}
        if parent:
            rec["spawnedFrom"] = {"sessionId": parent}
        self.write_abs(os.path.join(self.sessions(name), sid + ".json"), rec)
        self.write_abs(self.transcript(name, cwd, cli), text)

    def run(self, *args, ok=True, env_extra=None):
        ps = "\n".join([APP if n == "default" else f"{APP} --user-data-dir={self.profiles[n][0]}"
                        for n in self.open_apps] + self.other_processes)
        # Not the account of a Claude Code tab these tests may run in
        env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE_CODE_")}
        env.update(HOME=self.root, CLAUDE_CHAT_PS_OUTPUT=ps, **(env_extra or {}))
        r = subprocess.run(["/usr/bin/python3", "-I", TOOL, *args], capture_output=True, text=True, env=env)
        if ok and r.returncode != 0:
            raise AssertionError(f"{args} failed ({r.returncode}): {r.stderr}")
        return r

    def json(self, *args):
        return json.loads(self.run(*args, "--json").stdout)

    def read(self, name, cli):
        with open(self.transcript(name, "/tmp/proj", cli)) as f:
            return f.read()

    def cleanup(self):
        shutil.rmtree(self.root)


class ClaudeChatTest(unittest.TestCase):
    def setUp(self):
        self.h = Home()

    def tearDown(self):
        self.h.cleanup()

    def family(self, name="default"):
        h = self.h
        h.chat(name, "local_P", "cP", "Parent", "a\n", priorCliSessionIds=["cOld"])
        h.write_abs(h.transcript(name, "/tmp/proj", "cOld"), "old\n")
        h.chat(name, "local_C", "cC", "Child", "c\n", parent="local_P")
        h.chat(name, "local_G", "cG", "Grandchild", "g\n", parent="local_C")
        h.chat(name, "local_X", "cX", "Detached", "x\n", parent="local_P", lineageDetached=True)

    def test_profiles_from_multiprofile_and_names(self):
        self.h.write(".config/claude-chat-sync/config.json", {"names": {"default": "Personal"}})
        ps = {p["key"]: p for p in self.h.json("profiles")}
        self.assertEqual(list(ps), ["default", "work", "client"])
        self.assertEqual(ps["default"]["name"], "Personal")
        self.assertEqual(ps["work"]["email"], "work@example.com")
        self.assertFalse(ps["work"]["accountMismatch"])

    def test_copy_family_with_sub_chats(self):
        self.family()
        r = self.h.json("copy", "Parent", "--from", "default", "--to", "work")
        self.assertEqual([c["title"] for c in r["chats"]], ["Parent", "Child", "Grandchild"])
        self.assertTrue(all(c["state"] == "new" for c in r["chats"]))
        for sid in ("local_P", "local_C", "local_G"):
            self.assertTrue(os.path.exists(os.path.join(self.h.sessions("work"), sid + ".json")))
        self.assertFalse(os.path.exists(os.path.join(self.h.sessions("work"), "local_X.json")))
        self.assertTrue(os.path.exists(self.h.transcript("work", "/tmp/proj", "cOld")))

    def test_destination_app_open_is_refused(self):
        self.family()
        self.h.open_apps = {"work"}
        r = self.h.run("copy", "Parent", "--from", "default", "--to", "work", ok=False)
        self.assertEqual(r.returncode, 3)

    def test_move_trashes_source_and_restore_brings_it_back(self):
        self.family()
        r = self.h.json("copy", "Parent", "--from", "default", "--to", "work", "--move")
        self.assertTrue(all(c["after"] == "removed" for c in r["chats"]))
        sess = self.h.sessions("default")
        self.assertFalse(os.path.exists(os.path.join(sess, "local_P.json")))
        self.assertTrue(os.path.exists(os.path.join(sess, "deleted_cP")))
        self.assertFalse(os.path.exists(self.h.transcript("default", "/tmp/proj", "cP")))
        entries = self.h.json("trash", "list")
        self.assertEqual(len(entries), 3)
        for e in entries:
            self.h.run("trash", "restore", e["id"])
        self.assertTrue(os.path.exists(os.path.join(sess, "local_P.json")))
        self.assertFalse(os.path.exists(os.path.join(sess, "deleted_cP")))
        self.assertEqual(self.h.read("default", "cP"), "a\n")
        self.assertEqual(self.h.json("trash", "list"), [])

    def test_move_with_source_open_waits_for_quit(self):
        self.family()
        self.h.open_apps = {"default"}
        r = self.h.json("copy", "Parent", "--from", "default", "--to", "work", "--move")
        self.assertTrue(all(c["after"] == "remove-pending" for c in r["chats"]))
        self.assertTrue(os.path.exists(os.path.join(self.h.sessions("default"), "local_P.json")))
        # The child is continued in the source before the app quits: it must stay
        with open(self.h.transcript("default", "/tmp/proj", "cC"), "a") as f:
            f.write("more\n")
        self.h.open_apps = set()
        self.h.run("profiles")
        sess = self.h.sessions("default")
        self.assertFalse(os.path.exists(os.path.join(sess, "local_P.json")))
        self.assertTrue(os.path.exists(os.path.join(sess, "local_C.json")))
        self.assertEqual(self.h.json("pending", "list"), [])

    def test_archive_source(self):
        self.family()
        self.h.run("copy", "Parent", "--from", "default", "--to", "work", "--archive-source")
        with open(os.path.join(self.h.sessions("default"), "archived-sessions.idx")) as f:
            idx = json.load(f)
        self.assertIn("local_P", idx["archived"])

    def test_diverged_group_is_left_untouched_unless_forced(self):
        self.family()
        self.h.run("copy", "Parent", "--from", "default", "--to", "work")
        for name, extra in (("default", "D\n"), ("work", "W\n")):
            with open(self.h.transcript(name, "/tmp/proj", "cC"), "a") as f:
                f.write(extra)
        with open(self.h.transcript("default", "/tmp/proj", "cP"), "a") as f:
            f.write("newer\n")
        before = self.h.read("work", "cP")
        r = self.h.run("copy", "Parent", "--from", "default", "--to", "work", ok=False)
        self.assertEqual(r.returncode, 4)
        self.assertEqual(self.h.read("work", "cP"), before)
        self.h.run("copy", "Parent", "--from", "default", "--to", "work", "--force")
        self.assertEqual(self.h.read("work", "cC"), "c\nD\n")
        backups = [f for f in os.listdir(os.path.dirname(self.h.transcript("work", "/tmp/proj", "cC"))) if ".bak-" in f]
        self.assertEqual(len(backups), 1)

    def test_status_across_three_profiles(self):
        h = self.h
        h.chat("default", "local_A", "cA", "Same", "1\n")
        h.chat("work", "local_A", "cA", "Same", "1\n")
        h.chat("default", "local_B", "cB", "Ahead", "1\n2\n")
        h.chat("work", "local_B", "cB", "Ahead", "1\n")
        h.chat("client", "local_B", "cB", "Ahead", "1\n2\n")
        h.chat("default", "local_C", "cC", "Conflict", "1\nx\n")
        h.chat("client", "local_C", "cC", "Conflict", "1\ny\n")
        h.chat("work", "local_D", "cD", "Only", "1\n")
        st = h.json("status")
        self.assertEqual([p["key"] for p in st["profiles"]], ["default", "work", "client"])
        sides = {c["title"]: {k: s["state"] for k, s in c["sides"].items()} for c in st["chats"]}
        self.assertEqual(sides["Same"], {"default": "same", "work": "same"})
        self.assertEqual(sides["Ahead"], {"default": "latest", "work": "behind", "client": "latest"})
        self.assertEqual(sides["Conflict"], {"default": "diverged", "client": "diverged"})
        self.assertEqual(sides["Only"], {"work": "only"})

    def test_show_limits_profiles(self):
        self.h.write(".config/claude-chat-sync/config.json", {"show": ["client", "default"]})
        st = self.h.json("status")
        self.assertEqual([p["key"] for p in st["profiles"]], ["client", "default"])

    def test_open_apps_detected_and_lookalikes_ignored(self):
        h = self.h
        # This app's own process, and a helper: neither is a Claude Desktop
        h.other_processes = ["/Users/me/Applications/Claude Chat Sync.app/Contents/MacOS/ClaudeChatSync",
                             f"{APP} Helper --type=renderer"]
        running = {p["key"]: p["running"] for p in h.json("profiles")}
        self.assertEqual(running, {"default": False, "work": False, "client": False})
        h.open_apps = {"work"}
        running = {p["key"]: p["running"] for p in h.json("profiles")}
        self.assertEqual(running, {"default": False, "work": True, "client": False})

    def test_second_name_for_a_profile_folder_is_ignored(self):
        work_data = self.h.profiles["work"][0]
        self.h.write(".config/claude-chat-sync/config.json", {"profiles": [
            {"key": "again", "dataDir": work_data.replace("Claude-work", "Claude-WORK"), "configDir": "~/.claude-again"}]})
        self.assertEqual([p["key"] for p in self.h.json("profiles")], ["default", "work", "client"])

    def sync(self, *args):
        return {(c["title"], c["to"]): c["result"] for c in self.h.json("sync", *args)["chats"]}

    def test_sync_both_ways_only_what_is_safe(self):
        h = self.h
        h.chat("default", "local_A", "cA", "Only default", "1\n")
        h.chat("work", "local_B", "cB", "Only work", "1\n")
        h.chat("default", "local_C", "cC", "Behind in work", "1\n2\n")
        h.chat("work", "local_C", "cC", "Behind in work", "1\n")
        h.chat("default", "local_D", "cD", "Diverged", "1\nx\n")
        h.chat("work", "local_D", "cD", "Diverged", "1\ny\n")
        h.chat("default", "local_E", "cE", "Deleted in work", "1\n")
        h.write_abs(os.path.join(h.sessions("work"), "deleted_cE"), "1")
        h.chat("default", "local_F", "cF", "Same", "1\n")
        h.chat("work", "local_F", "cF", "Same", "1\n")
        h.chat("default", "local_G", "cG", "Archived", "1\n", isArchived=True)

        dry = self.sync("--profiles", "default,work", "--dry-run")
        self.assertFalse(os.path.exists(os.path.join(h.sessions("work"), "local_A.json")))
        self.assertEqual(dry, self.sync("--profiles", "default,work"))
        self.assertEqual(dry, {
            ("Only default", "work"): "copied", ("Only work", "default"): "copied",
            ("Behind in work", "work"): "updated", ("Diverged", None): "conflict",
            ("Deleted in work", "work"): "deleted", ("Archived", "work"): "copied",
        })
        self.assertEqual(h.read("work", "cA"), "1\n")
        self.assertEqual(h.read("default", "cB"), "1\n")
        self.assertEqual(h.read("work", "cC"), "1\n2\n")
        self.assertEqual(h.read("work", "cD"), "1\ny\n")
        self.assertFalse(os.path.exists(os.path.join(h.sessions("work"), "local_E.json")))
        with open(os.path.join(h.sessions("work"), "local_G.json")) as f:
            self.assertTrue(json.load(f)["isArchived"])
        # Nothing left but the conflict and the deleted chat
        self.assertEqual(set(self.sync("--profiles", "default,work").values()), {"conflict", "deleted"})

    def test_sync_waits_for_open_app_and_keeps_moved_chats_away(self):
        h = self.h
        h.chat("work", "local_B", "cB", "Only work", "1\n")
        self.family()
        h.run("copy", "Parent", "--from", "default", "--to", "work", "--move")
        h.open_apps = {"default"}
        # The move left Claude's tombstones in default; the detached chat was not part of it
        self.assertEqual(self.sync("--profiles", "default,work"), {
            ("Only work", "default"): "waiting", ("Parent", "default"): "deleted",
            ("Child", "default"): "deleted", ("Grandchild", "default"): "deleted", ("Detached", "work"): "copied",
        })
        self.assertFalse(os.path.exists(os.path.join(h.sessions("default"), "local_B.json")))
        self.assertFalse(os.path.exists(os.path.join(h.sessions("default"), "local_P.json")))
        self.assertTrue(os.path.exists(os.path.join(h.sessions("work"), "local_X.json")))

    def test_sync_sub_chat_needs_its_parent(self):
        h = self.h
        self.family()
        h.write_abs(os.path.join(h.sessions("work"), "deleted_cP"), "1")
        got = self.sync("--profiles", "default,work")
        self.assertEqual(got[("Parent", "work")], "deleted")
        self.assertEqual(got[("Child", "work")], "parent")
        self.assertEqual(got[("Grandchild", "work")], "parent")
        # A sub-chat already there is still kept up to date
        h.chat("work", "local_C", "cC", "Child", "c\n", parent="local_P")
        with open(h.transcript("default", "/tmp/proj", "cC"), "a") as f:
            f.write("more\n")
        got = self.sync("--profiles", "default,work")
        self.assertEqual(got[("Child", "work")], "updated")
        self.assertEqual(h.read("work", "cC"), "c\nmore\n")


class DesktopOnlyTest(unittest.TestCase):
    """A Desktop-only profile shares ~/.claude, and with it the conversations, with the default profile."""

    def setUp(self):
        self.h = Home(extra=(), desktop_only=("work",))

    def tearDown(self):
        self.h.cleanup()

    def test_listed_without_a_code_account(self):
        ps = {p["key"]: p for p in self.h.json("profiles")}
        self.assertEqual(list(ps), ["default", "work"])
        self.assertEqual(ps["work"]["codeDir"], ps["default"]["codeDir"])
        self.assertFalse(ps["work"]["accountMismatch"])  # the shared Code sign-in is the default profile's
        self.assertEqual(ps["work"]["account"], "acct-work")
        self.assertIsNone(ps["work"]["email"])

    def test_email_learned_from_a_desktop_code_tab_is_remembered(self):
        # Run once from inside the work profile's Code tab, which gives its account and e-mail
        self.h.run("profiles", env_extra={"CLAUDE_CODE_ACCOUNT_UUID": "acct-work",
                                          "CLAUDE_CODE_USER_EMAIL": "me@work.example"})
        ps = {p["key"]: p for p in self.h.json("profiles")}
        self.assertEqual(ps["work"]["email"], "me@work.example")
        self.assertEqual(ps["default"]["email"], "default@example.com")

    def test_copy_and_move_only_move_the_card(self):
        h = self.h
        h.chat("default", "local_P", "cP", "Parent", "a\n")
        h.chat("default", "local_C", "cC", "Child", "c\n", parent="local_P")
        r = h.json("copy", "Parent", "--from", "default", "--to", "work")
        self.assertEqual([c["state"] for c in r["chats"]], ["same", "same"])
        self.assertTrue(os.path.exists(os.path.join(h.sessions("work"), "local_P.json")))
        st = {c["title"]: {k: s["state"] for k, s in c["sides"].items()} for c in h.json("status")["chats"]}
        self.assertEqual(st["Parent"], {"default": "same", "work": "same"})
        # Moving it away from default must leave the conversation, which work uses too
        h.run("copy", "Parent", "--from", "default", "--to", "work", "--move")
        self.assertFalse(os.path.exists(os.path.join(h.sessions("default"), "local_P.json")))
        self.assertFalse(os.path.exists(os.path.join(h.sessions("default"), "deleted_cP")))
        self.assertEqual(h.read("default", "cP"), "a\n")
        # No tombstone, so the trash is what keeps sync from bringing it back
        got = {(c["title"], c["to"]): c["result"] for c in h.json("sync")["chats"]}
        self.assertEqual(got, {("Parent", "default"): "moved", ("Child", "default"): "moved"})
        for e in h.json("trash", "list"):
            h.run("trash", "restore", e["id"])
        self.assertTrue(os.path.exists(os.path.join(h.sessions("default"), "local_P.json")))
        self.assertEqual(h.read("default", "cP"), "a\n")

    def test_sync_copies_cards_both_ways(self):
        h = self.h
        h.chat("default", "local_A", "cA", "From default", "1\n")
        h.chat("work", "local_B", "cB", "From work", "2\n")
        got = {(c["title"], c["to"]): c["result"] for c in h.json("sync")["chats"]}
        self.assertEqual(got, {("From default", "work"): "copied", ("From work", "default"): "copied"})
        self.assertTrue(os.path.exists(os.path.join(h.sessions("work"), "local_A.json")))
        self.assertTrue(os.path.exists(os.path.join(h.sessions("default"), "local_B.json")))
        self.assertEqual(h.json("sync")["chats"], [])
        transcripts = os.path.dirname(h.transcript("default", "/tmp/proj", "cA"))
        self.assertEqual(sorted(os.listdir(transcripts)), ["cA.jsonl", "cB.jsonl"])


if __name__ == "__main__":
    unittest.main()
