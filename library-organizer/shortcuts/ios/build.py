#!/usr/bin/env python3
"""Generate the iOS shortcuts that drive the server-side sync over SSH.

Each shortcut uses "Run Script Over SSH" against LXC 101 (Docker host), which
is reachable from the phone through the Tailscale subnet router.

    python3 build.py            # writes *.shortcut next to this file
    ./sign.sh                   # signs them into *.signed.shortcut (macOS only)

On first import, open each SSH action once and pick "SSH Key" authentication:
Shortcuts generates a key per device; append its public key to
/root/.ssh/authorized_keys on LXC 101.

Error handling: every remote command ends in `2>&1 || true`, so the SSH action
always returns the script's output instead of failing with an opaque error.
The server scripts prefix problems with "ERROR:" / "WARN:", which the shortcuts
check to decide whether to stop or carry on.
"""

import plistlib
import uuid
from pathlib import Path

HOST = "10.1.1.101"
USER = "root"
PORT = "22"
SERVER_DIR = "/opt/alpargatify/library-organizer/server"
INTERACTIVE_CMD = f"ssh {USER}@{HOST} {SERVER_DIR}/sync.sh interactive"

OUT_DIR = Path(__file__).resolve().parent
PLACEHOLDER = "￼"

# WFCondition codes used by the Shortcuts app.
CONTAINS = 99
HAS_NO_VALUE = 101

SSH_RESULT = "Shell Script Result"


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


# --- building blocks ---------------------------------------------------------

def ssh(action_uuid, command, input_uuid=None, input_name=None):
    params = {
        "UUID": action_uuid,
        "WFSSHHost": HOST,
        "WFSSHPort": PORT,
        "WFSSHUser": USER,
        "WFSSHAuthenticationType": "SSH Key",
        "WFSSHScript": f"{SERVER_DIR}/{command} 2>&1 || true",
    }
    if input_uuid:
        params["WFInput"] = attachment(input_uuid, input_name)
    return action("runsshscript", **params)


def show(action_uuid, name):
    return action("showresult", Text=token_string(action_uuid, name))


def alert(title, message=None, message_uuid=None, message_name=None):
    params = {"WFAlertActionTitle": title, "WFAlertActionCancelButtonShown": False}
    if message_uuid:
        params["WFAlertActionMessage"] = token_string(message_uuid, message_name)
    elif message:
        params["WFAlertActionMessage"] = message
    return action("alert", **params)


def text(action_uuid, value):
    return action("gettext", UUID=action_uuid, WFTextActionText=value)


def stop():
    return action("exit")


def if_block(condition, input_uuid, input_name, then, otherwise=None, string=None):
    group = new_uuid()
    start = {
        "GroupingIdentifier": group,
        "WFControlFlowMode": 0,
        "WFCondition": condition,
        "WFInput": {"Type": "Variable", "Variable": attachment(input_uuid, input_name)},
    }
    if string is not None:
        start["WFConditionalActionString"] = string
    actions = [action("conditional", **start), *then]
    if otherwise:
        actions += [action("conditional", GroupingIdentifier=group, WFControlFlowMode=1), *otherwise]
    actions.append(action("conditional", GroupingIdentifier=group, WFControlFlowMode=2, UUID=new_uuid()))
    return actions


def menu(prompt, cases):
    """cases: list of (title, [actions])."""
    group = new_uuid()
    actions = [action("choosefrommenu", GroupingIdentifier=group, WFControlFlowMode=0,
                      WFMenuPrompt=prompt, WFMenuItems=[title for title, _ in cases])]
    for title, body in cases:
        actions.append(action("choosefrommenu", GroupingIdentifier=group, WFControlFlowMode=1,
                              WFMenuItemTitle=title))
        actions += body
    actions.append(action("choosefrommenu", GroupingIdentifier=group, WFControlFlowMode=2, UUID=new_uuid()))
    return actions


def pick_and_move(list_cmd, empty_message, prompt):
    """List folders on the server, let the user pick some, move them to the inbox.

    Returns (actions, uuid of the move result). Stops the shortcut when there is
    nothing to pick or the listing itself failed.
    """
    listed, split, chosen, joined, moved = (new_uuid() for _ in range(5))
    actions = [ssh(listed, list_cmd)]
    actions += if_block(HAS_NO_VALUE, listed, SSH_RESULT, [alert("Res a moure", empty_message), stop()])
    actions += if_block(CONTAINS, listed, SSH_RESULT,
                        [alert("Error al servidor", message_uuid=listed, message_name=SSH_RESULT), stop()],
                        string="ERROR")
    actions += [
        action("text.split", UUID=split, text=attachment(listed, SSH_RESULT), WFTextSeparator="New Lines"),
        action("choosefromlist", UUID=chosen, WFInput=attachment(split, "Split Text"),
               WFChooseFromListActionPrompt=prompt, WFChooseFromListActionSelectMultiple=True),
        action("text.combine", UUID=joined, text=attachment(chosen, "Chosen Item"), WFTextSeparator="New Lines"),
        # Names go through stdin: they may contain quotes, brackets, spaces...
        ssh(moved, "inbox.sh move -", joined, "Combined Text"),
    ]
    actions += if_block(CONTAINS, moved, SSH_RESULT,
                        [alert("Alguns àlbums no s'han pogut moure", message_uuid=moved, message_name=SSH_RESULT)],
                        otherwise=[alert("Fet", message_uuid=moved, message_name=SSH_RESULT)],
                        string="ERROR")
    return actions, moved


def start_sync():
    ran = new_uuid()
    return [ssh(ran, "sync.sh auto"),
            *if_block(CONTAINS, ran, SSH_RESULT,
                      [alert("No s'ha pogut llançar el sync", message_uuid=ran, message_name=SSH_RESULT)],
                      otherwise=[alert("Sync",
                                       message_uuid=ran, message_name=SSH_RESULT)],
                      string="ERROR")]


def show_status(arg=""):
    ran = new_uuid()
    return [ssh(ran, f"status.sh {arg}".strip()), show(ran, SSH_RESULT)]


HELP = f"""Ordre dels passos:

1. Moure àlbums a l'inbox — tria carpetes FLAC de slskd/ o torrents/. Els de slskd es mouen; els de torrents es copien (segueixen fent seed).

2. Llançar sync automàtic — importa l'inbox amb beets, converteix a Opus i ho deixa a Navidrome. Corre al servidor: pots tancar l'app.

3. Veure progrés — fase (1/3 importació, 2/3 conversió, 3/3 còpia), àlbums fets/total i temps. Repeteix fins que digui "finished".

4. Àlbums fallits — els que beets no ha importat (Skip, duplicat, sense match, mp3, >24/48) són a navidrome_inbox_failed/ amb un .txt que explica el motiu.

5. Reintentar fallits — els torna a l'inbox. Després, des d'una app SSH (Termius/Blink):
{INTERACTIVE_CMD}
i tria tu el match de cada àlbum. Si es talla la connexió, torna a executar-lo i reprens on eres."""


def guided():
    move_actions, _ = pick_and_move(
        "inbox.sh list",
        "No hi ha cap carpeta amb FLAC a downloads/slskd ni downloads/torrents.",
        "Àlbums a moure a l'inbox",
    )
    retry_actions, _ = pick_and_move(
        "inbox.sh list failed",
        "No hi ha àlbums fallits.",
        "Àlbums fallits a reintentar",
    )
    help_text, cmd_text = new_uuid(), new_uuid()
    after_move = menu("Següent pas", [
        ("2. Llançar el sync automàtic ara", start_sync()),
        ("Més tard", []),
    ])
    return workflow(
        "Alpargatify",
        menu("Alpargatify — passos en ordre", [
            ("1. Moure àlbums a l'inbox", move_actions + after_move),
            ("2. Llançar sync automàtic", start_sync()),
            ("3. Veure progrés", show_status()),
            ("4. Àlbums fallits", show_status("failed")),
            ("5. Reintentar fallits (interactiu)", retry_actions + [
                text(cmd_text, INTERACTIVE_CMD),
                action("setclipboard", WFInput=attachment(cmd_text, "Text")),
                alert("Ara, mode interactiu",
                      f"Comanda copiada al porta-retalls. Obre Termius/Blink i enganxa-la:\n\n{INTERACTIVE_CMD}"),
            ]),
            ("Com funciona?", [text(help_text, HELP), show(help_text, "Text")]),
        ]),
        glyph=59511,
        color=4282601983,
    )


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
    actions, _ = pick_and_move(
        "inbox.sh list",
        "No hi ha cap carpeta amb FLAC a downloads/slskd ni downloads/torrents.",
        "Àlbums a moure a l'inbox",
    )
    return workflow("Mou a inbox", actions, glyph=59446, color=4282601983)


def run_sync():
    return workflow("Sync server", start_sync(), glyph=59477, color=4271458815)


def sync_status():
    return workflow("Estat sync", show_status(), glyph=59448, color=4292093695)


def main():
    for wf in (guided(), move_to_inbox(), run_sync(), sync_status()):
        path = OUT_DIR / f"{wf['WFWorkflowName']}.shortcut"
        with path.open("wb") as fh:
            plistlib.dump(wf, fh, fmt=plistlib.FMT_XML)
        print(path)


if __name__ == "__main__":
    main()
