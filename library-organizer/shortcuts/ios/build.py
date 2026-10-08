#!/usr/bin/env python3
"""Generate the iOS shortcuts that drive the server-side sync over SSH.

Each shortcut uses "Run Script Over SSH" against LXC 101 (Docker host), which
is reachable from the phone through the Tailscale subnet router.

    python3 build.py            # writes *.shortcut next to this file
    ./sign.sh                   # signs them into *.signed.shortcut (macOS only)

On first import, open each SSH action once and pick "SSH Key" authentication:
Shortcuts generates a key per device; append its public key to
/root/.ssh/authorized_keys on LXC 101.
"""

import plistlib
import uuid
from pathlib import Path

HOST = "10.1.1.101"
USER = "root"
PORT = "22"
SERVER_DIR = "/opt/alpargatify/library-organizer/server"

OUT_DIR = Path(__file__).resolve().parent
PLACEHOLDER = "￼"


def new_uuid():
    return str(uuid.uuid4()).upper()


def output_ref(action_uuid, name):
    return {"OutputName": name, "OutputUUID": action_uuid, "Type": "ActionOutput"}


def attachment(action_uuid, name):
    """Whole-parameter variable (WFInput and friends)."""
    return {"Value": output_ref(action_uuid, name), "WFSerializationType": "WFTextTokenAttachment"}


def token_string(action_uuid, name):
    """Text parameter that is just one variable."""
    return {
        "Value": {
            "attachmentsByRange": {"{0, 1}": output_ref(action_uuid, name)},
            "string": PLACEHOLDER,
        },
        "WFSerializationType": "WFTextTokenString",
    }


def action(identifier, **params):
    return {"WFWorkflowActionIdentifier": f"is.workflow.actions.{identifier}", "WFWorkflowActionParameters": params}


def ssh(action_uuid, script, input_uuid=None, input_name=None):
    params = {
        "UUID": action_uuid,
        "WFSSHHost": HOST,
        "WFSSHPort": PORT,
        "WFSSHUser": USER,
        "WFSSHAuthenticationType": "SSH Key",
        "WFSSHScript": script,
    }
    if input_uuid:
        params["WFInput"] = attachment(input_uuid, input_name)
    return action("runsshscript", **params)


def show(action_uuid, name):
    return action("showresult", Text=token_string(action_uuid, name))


def workflow(name, actions, glyph, color):
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2700.0.4",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": glyph, "WFWorkflowIconStartColor": color},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowName": name,
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": [],
    }


def move_to_inbox():
    listed, split, chosen, joined, moved = (new_uuid() for _ in range(5))
    return workflow(
        "Mou a inbox",
        [
            ssh(listed, f"{SERVER_DIR}/inbox.sh list"),
            action("text.split", UUID=split, text=attachment(listed, "Shell Script Result"),
                   WFTextSeparator="New Lines"),
            action("choosefromlist", UUID=chosen, WFInput=attachment(split, "Split Text"),
                   WFChooseFromListActionPrompt="Àlbums a moure a l'inbox",
                   WFChooseFromListActionSelectMultiple=True),
            action("text.combine", UUID=joined, text=attachment(chosen, "Chosen Item"),
                   WFTextSeparator="New Lines"),
            # Names go through stdin: they may contain quotes, brackets, spaces...
            ssh(moved, f"{SERVER_DIR}/inbox.sh move -", joined, "Combined Text"),
            show(moved, "Shell Script Result"),
        ],
        glyph=59446,
        color=4282601983,
    )


def run_sync():
    ran = new_uuid()
    return workflow(
        "Sync server",
        [ssh(ran, f"{SERVER_DIR}/sync.sh auto 2>&1"), show(ran, "Shell Script Result")],
        glyph=59477,
        color=4271458815,
    )


def sync_status():
    ran = new_uuid()
    return workflow(
        "Estat sync",
        [ssh(ran, f"{SERVER_DIR}/status.sh 2>&1"), show(ran, "Shell Script Result")],
        glyph=59448,
        color=4292093695,
    )


def main():
    for wf in (move_to_inbox(), run_sync(), sync_status()):
        path = OUT_DIR / f"{wf['WFWorkflowName']}.shortcut"
        with path.open("wb") as fh:
            plistlib.dump(wf, fh, fmt=plistlib.FMT_XML)
        print(path)


if __name__ == "__main__":
    main()
