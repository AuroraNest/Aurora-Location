#!/usr/bin/env python3
"""Build the installable Aurora cellular helper Shortcut without importing it."""

from __future__ import annotations

import plistlib
import shutil
import subprocess
import sys
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = ROOT / "build" / "Shortcuts"
UNSIGNED_PATH = BUILD_DIR / "AuroraCellular.unsigned.shortcut"
SIGNED_PATH = ROOT / "AuroraLocation" / "Resources" / "AuroraCellular.shortcut"
NAMESPACE = uuid.UUID("9e2f0f51-8d55-56c0-b0f5-f0c646f8901f")
EXTENSION_INPUT_TOKEN = {
    "Value": {"Type": "ExtensionInput"},
    "WFSerializationType": "WFTextTokenAttachment",
}
def action(identifier: str, parameters: dict) -> dict:
    return {
        "WFWorkflowActionIdentifier": identifier,
        "WFWorkflowActionParameters": parameters,
    }


def action_output(identifier: str, name: str) -> dict:
    return {
        "Value": {"OutputName": name, "OutputUUID": identifier, "Type": "ActionOutput"},
        "WFSerializationType": "WFTextTokenAttachment",
    }


def conditional_input(token: dict) -> dict:
    # Conditional actions serialize their input as a Variable wrapper.
    return {"Type": "Variable", "Variable": token}


def conditional_start(value: str, token: dict, group: str, condition: int = 4) -> dict:
    return action(
        "is.workflow.actions.conditional",
        {
            "WFCondition": condition,
            "WFConditionalActionString": value,
            "WFControlFlowMode": 0,
            "WFInput": conditional_input(token),
            "GroupingIdentifier": group,
        },
    )


def conditional_boundary(mode: int, group: str) -> dict:
    return action(
        "is.workflow.actions.conditional",
        {"WFControlFlowMode": mode, "GroupingIdentifier": group},
    )


def cellular(enabled: bool) -> dict:
    return action("is.workflow.actions.cellulardata.set", {"OnValue": enabled})


def wifi(enabled: bool) -> dict:
    return action("is.workflow.actions.wifi.set", {"OnValue": enabled})


def split_text(identifier: str) -> dict:
    return action(
        "is.workflow.actions.text.split",
        {
            "text": EXTENSION_INPUT_TOKEN,
            "separator": "newLines",
            "UUID": identifier,
            "CustomOutputName": "Aurora Request Lines",
        },
    )


def list_item(source: dict, index: str, identifier: str, name: str) -> dict:
    return action(
        "is.workflow.actions.getitemfromlist",
        {
            "WFInput": source,
            "WFItemSpecifier": "Item At Index",
            "WFItemIndex": index,
            "UUID": identifier,
            "CustomOutputName": name,
        },
    )


def open_url(token: dict) -> dict:
    return action("is.workflow.actions.openurl", {"WFInput": token})


def workflow() -> dict:
    """Use fixed UUIDv5 groups so the unsigned plist has stable bytes."""
    callback_group = str(uuid.uuid5(NAMESPACE, "callback"))
    prepare_group = str(uuid.uuid5(NAMESPACE, "prepare"))
    offline_group = str(uuid.uuid5(NAMESPACE, "offline"))
    restore_group = str(uuid.uuid5(NAMESPACE, "restore"))
    split_identifier = str(uuid.uuid5(NAMESPACE, "request-lines"))
    phase_identifier = str(uuid.uuid5(NAMESPACE, "phase"))
    callback_identifier = str(uuid.uuid5(NAMESPACE, "callback-url"))
    lines = action_output(split_identifier, "Aurora Request Lines")
    phase = action_output(phase_identifier, "Aurora Phase")
    callback = action_output(callback_identifier, "Aurora Callback URL")
    actions = [
        split_text(split_identifier),
        list_item(lines, "1", phase_identifier, "Aurora Phase"),
        list_item(lines, "2", callback_identifier, "Aurora Callback URL"),
        conditional_start("auroralocation-cellular://callback?", callback, callback_group, condition=8),
        conditional_start("prepare", phase, prepare_group),
        wifi(False),
        cellular(True),
        open_url(callback),
        conditional_boundary(1, prepare_group),
        conditional_start("offline", phase, offline_group),
        cellular(False),
        open_url(callback),
        conditional_boundary(1, offline_group),
        conditional_start("restore", phase, restore_group),
        cellular(True),
        open_url(callback),
        conditional_boundary(1, restore_group),
        conditional_boundary(2, restore_group),
        conditional_boundary(2, offline_group),
        conditional_boundary(2, prepare_group),
        conditional_boundary(2, callback_group),
    ]
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientRelease": "5037.0.17",
        "WFWorkflowClientVersion": "5037.0.17",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 59755, "WFWorkflowIconStartColor": 463140863},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowName": "Aurora 蜂窝助手 2",
        "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowTypes": ["ActionExtension"],
    }


def validate(document: dict) -> None:
    """Check the two-line request parser, guarded switch order and callback route."""
    assert document["WFWorkflowName"] == "Aurora 蜂窝助手 2"
    assert document["WFWorkflowInputContentItemClasses"] == ["WFStringContentItem"]
    actions = document["WFWorkflowActions"]
    identifiers = [item["WFWorkflowActionIdentifier"] for item in actions]
    expected_identifiers = [
        "is.workflow.actions.text.split",
        "is.workflow.actions.getitemfromlist",
        "is.workflow.actions.getitemfromlist",
        "is.workflow.actions.conditional",
        "is.workflow.actions.conditional",
        "is.workflow.actions.wifi.set",
        "is.workflow.actions.cellulardata.set",
        "is.workflow.actions.openurl",
        "is.workflow.actions.conditional",
        "is.workflow.actions.conditional",
        "is.workflow.actions.cellulardata.set",
        "is.workflow.actions.openurl",
        "is.workflow.actions.conditional",
        "is.workflow.actions.conditional",
        "is.workflow.actions.cellulardata.set",
        "is.workflow.actions.openurl",
        "is.workflow.actions.conditional",
        "is.workflow.actions.conditional",
        "is.workflow.actions.conditional",
        "is.workflow.actions.conditional",
        "is.workflow.actions.conditional",
    ]
    assert identifiers == expected_identifiers

    starts = [item["WFWorkflowActionParameters"] for item in actions if item["WFWorkflowActionParameters"].get("WFControlFlowMode") == 0]
    assert [item["WFConditionalActionString"] for item in starts] == ["auroralocation-cellular://callback?", "prepare", "offline", "restore"]
    assert [item["WFCondition"] for item in starts] == [8, 4, 4, 4]
    assert all(item["WFInput"]["Type"] == "Variable" and item["WFInput"]["Variable"]["WFSerializationType"] == "WFTextTokenAttachment" for item in starts)
    assert actions[0]["WFWorkflowActionParameters"]["text"] == EXTENSION_INPUT_TOKEN
    assert actions[0]["WFWorkflowActionParameters"]["separator"] == "newLines"
    assert [item["WFWorkflowActionParameters"]["WFItemIndex"] for item in actions[1:3]] == ["1", "2"]
    assert [item["WFWorkflowActionParameters"]["OnValue"] for item in actions if item["WFWorkflowActionIdentifier"] in {"is.workflow.actions.wifi.set", "is.workflow.actions.cellulardata.set"}] == [False, True, False, True]
    assert [item["WFWorkflowActionParameters"]["WFInput"] for item in actions if item["WFWorkflowActionIdentifier"] == "is.workflow.actions.openurl"] == [starts[0]["WFInput"]["Variable"], starts[0]["WFInput"]["Variable"], starts[0]["WFInput"]["Variable"]]


def main() -> None:
    document = workflow()
    validate(document)
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    with UNSIGNED_PATH.open("wb") as output:
        plistlib.dump(document, output, fmt=plistlib.FMT_BINARY, sort_keys=True)
    with UNSIGNED_PATH.open("rb") as source:
        validate(plistlib.load(source))

    shortcuts = shutil.which("shortcuts")
    if shortcuts is None:
        raise RuntimeError("shortcuts command is required to sign AuroraCellular.shortcut")
    subprocess.run(
        [shortcuts, "sign", "--mode", "anyone", "--input", str(UNSIGNED_PATH), "--output", str(SIGNED_PATH)],
        check=True,
    )
    print(f"built {UNSIGNED_PATH}")
    print(f"signed {SIGNED_PATH}")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
