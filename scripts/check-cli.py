"""Exercise the packaged CLI with an isolated fictional vault."""

import json
from pathlib import Path
import stat
import subprocess
import sys
from tempfile import TemporaryDirectory


def verify(binary: Path, root: Path) -> None:
    vault = root / "Fictional vault.json"

    def run(*args: str, stdin: object = None, ok: bool = True, path: Path = vault) -> str:
        result = subprocess.run(
            [str(binary), *args, "--vault", str(path)],
            input=None if stdin is None else json.dumps(stdin, ensure_ascii=False),
            capture_output=True,
            text=True,
            check=False,
        )
        if ok:
            assert result.returncode == 0, (args, result.stderr)
            assert not result.stderr, (args, result.stderr)
        else:
            assert result.returncode != 0 and result.stderr and not result.stdout, (args, result)
        return result.stdout

    def output(*args: str, stdin: object = None) -> object:
        return json.loads(run(*args, stdin=stdin))

    assert "preset save" in run("--help")
    assert output("profile", "create", "Demo", "--id", "demo")["id"] == "demo"
    assert stat.S_IMODE(vault.stat().st_mode) == 0o600
    assert output("profiles")[0]["recordCount"] == 0

    output("record", "add", "--kind", "contact", "--id", "contact", "--label", "Alex Example",
           "--fields", "-", stdin={"name": "Alex Example", "email": "alex@example.com"})
    output("record", "update", "contact", "--aliases", "-", stdin={";mail": "email"})
    assert run("get", "contact", ";mail").strip() == "alex@example.com"
    assert output("search", ";mail")[0]["field"] == "/email"

    output("record", "add", "--kind", "employment", "--id", "job", "--label", "Example job",
           "--fields", "-", stdin={
               "title": "Coordinator",
               "startDate": "2024-05",
               "endDate": "present",
               "responsibilities": ["Published guides", "Private draft"],
           })
    assert len(output("records", "--kind", "employment")) == 1
    assert output("record", "show", "job")["fields"]["endDate"] == "Present"
    assert run("get", "job", "/startDate", "--representation", "Year").strip() == "2024"
    run("get", "job", "/startDate", "--representation", "Invalid", ok=False)

    plan = output("selection", "--resume", "recommended")
    plan["records"][1]["fields"]["responsibilities"] = [0]
    preview = output("export", "--selection", "-", stdin=plan)
    assert "Published guides" in preview["experience_markdown"]
    assert "Private draft" not in preview["experience_markdown"]
    output("preset", "save", "resume", "--selection", "-", stdin=plan)
    assert run("presets").strip() == "resume"
    assert output("export", "--preset", "resume") == preview
    structured = output("export", "--preset", "resume", "--format", "structured")
    assert structured["records"][1]["fields"]["responsibilities"] == ["Published guides"]

    before = vault.read_bytes()
    run("record", "update", "job", "--set", "endDate=invalid", ok=False)
    run("record", "delete", "job", ok=False)
    run("profile", "delete", "demo", "--yes", ok=False)
    assert before == vault.read_bytes()

    output("record", "update", "job", "--fields", "-", stdin={
        "responsibilities": ["Revised guide", "Private draft"],
    })
    run("export", "--preset", "resume", ok=False)
    saved_plan = output("preset", "show", "resume")
    assert saved_plan == plan
    run("preset", "save", "resume", "--selection", "-", stdin=saved_plan, ok=False)
    output("preset", "save", "resume", "--selection", "-", "--replace", stdin=saved_plan)
    assert "Revised guide" in output("export", "--preset", "resume")["experience_markdown"]

    incoming = {"format": "veradata-import", "version": 1, "records": [
        {"id": "job", "kind": "employment", "fields": {"title": "Senior Coordinator"}},
    ]}
    before = vault.read_bytes()
    preview = output("import", "-", "--on-match", "update", stdin=incoming)
    assert not preview["applied"] and preview["records"][0]["target"] == "job"
    assert before == vault.read_bytes()
    assert output("import", "-", "--on-match", "update", "--apply", stdin=incoming)["applied"]
    assert "Senior Coordinator" in output("export", "--preset", "resume")["experience_markdown"]

    output("profile", "create", "Second", "--id", "second")
    output("record", "add", "--profile", "second", "--kind", "contact", "--id", "second-person",
           "--label", "Second Example")
    run("profile", "rename", "second", "Other")
    assert output("records", "--profile", "other")[0]["id"] == "second-person"
    mobile = output("export-phone", "--pick", "demo:contact", "--pick", "second:second-person")
    assert [list(p["records"][0]["fields"]) for p in mobile["profiles"]] == [["email", "name"], []]
    assert len(output("export-phone", "--profile", "demo", "--all")["profiles"][0]["records"]) == 2

    assert run("shortcut", "off").strip() == "off"
    backup = output("backup")
    restored = root / "restore.json"
    restored.write_text("invalid JSON")
    run("restore", "-", path=restored, stdin=backup, ok=False)
    assert restored.read_text() == "invalid JSON"
    run("restore", "-", "--yes", path=restored, stdin=backup)
    assert json.loads(run("backup", path=restored)) == backup
    assert run("presets", path=restored) == ""

    verify_transactions(binary, vault, output, run)

    run("record", "delete", "second-person", "--profile", "second", "--yes")
    run("profile", "delete", "second", "--yes")
    run("preset", "delete", "resume", ok=False)
    run("preset", "delete", "resume", "--yes")
    assert run("presets") == ""


def verify_transactions(binary: Path, vault: Path, output, run) -> None:
    """Preview exact batches and race two independent writers against that same state."""
    def change(headline: str) -> dict:
        return {"version": 1, "profile": "demo", "operations": [
            {"operation": "record.update", "record": "contact", "fields": {"headline": headline}},
            {"operation": "record.update", "record": "job", "fields": {"responsibilities": ["Checked intake"]}},
            {"operation": "preset.update", "preset": "resume", "record": "contact", "fields": {"headline": True}},
            {"operation": "preset.update", "preset": "resume", "record": "job", "fields": {"responsibilities": True}},
        ]}

    stages = [change("Operations Associate"), change("Operations Coordinator")]
    file_before = vault.read_bytes()
    previews = [output("apply", "-", stdin=stage) for stage in stages]
    assert vault.read_bytes() == file_before
    assert all("Operations Associate" not in json.dumps(p) for p in previews)
    assert "Operations Associate" in run("apply", "-", "--human", "--show-values", stdin=stages[0])
    assert all(p["changed"] and not p["committed"] for p in previews)

    children = [subprocess.Popen(
        [str(binary), "apply", "-", "--apply", "--expect", preview["token"], "--json-errors", "--vault", str(vault)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    ) for preview in previews]
    for child, stage in zip(children, stages):
        assert child.stdin is not None
        child.stdin.write(json.dumps(stage))
        child.stdin.close()
        child.stdin = None
    results = [child.communicate(timeout=15) for child in children]
    statuses = [child.returncode for child in children]
    assert sorted(statuses) == [0, 3], (statuses, results)
    winner = statuses.index(0)
    revision = json.loads(results[winner][0])["revision"]
    assert json.loads(results[1 - winner][1])["error"] == "conflict"
    record = output("record", "show", "contact")
    assert record["fields"]["headline"] == stages[winner]["operations"][0]["fields"]["headline"]
    assert output("export", "--preset", "resume")["headline"] == record["fields"]["headline"]
    assert "Checked intake" in output("export", "--preset", "resume")["experience_markdown"]
    assert not output("apply", "-", stdin=stages[winner])["changed"]

    output("record", "update", "job", "--fields", "-", stdin={"responsibilities": []})
    assert "Checked intake" not in output("export", "--preset", "resume")["experience_markdown"]
    patch = output("preset", "update", "resume", "--record", "contact", "--exclude", "headline")
    assert patch["changed"]
    output("preset", "update", "resume", "--record", "contact", "--exclude", "headline",
           "--apply", "--expect", patch["token"])
    assert "headline" not in output("export", "--preset", "resume")

    preview = output("history", "restore", revision)
    output("history", "restore", revision, "--apply", "--expect", preview["token"])
    assert "headline" not in output("record", "show", "contact")["fields"]
    assert output("history")[0]["summary"] == "Restore revision"
    assert output("history", "prune", "--keep", "2")["pruningCandidates"]
    output("history", "retention", "--keep", "2", "--apply")
    assert len(output("history")) == 2


if __name__ == "__main__":
    with TemporaryDirectory(prefix="veradata-cli-") as directory:
        verify(Path(sys.argv[1]).resolve(), Path(directory))
    print("VeraData CLI integration checks passed.")
