/*
 * Appearance settings — the widget's colors, always custom. Ships the classic
 * palette (green session / blue weekly / orange warn / red crit / white text);
 * anyone who dislikes it just edits the values. There is no "follow the Plasma
 * theme" mode — what we ship is the look, and it's fully editable.
 *
 * Layout mirrors the original prototype: colors grouped under section headers
 * (Bar / Warning / Text) with a Reset-to-defaults button. Inputs are KDE's
 * native color-wheel pickers rather than the prototype's raw hex fields.
 */
import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kquickcontrols as KQControls

Kirigami.FormLayout {
    // Each cfg_<name> alias binds a control to the matching kcfg key in main.xml.
    property alias cfg_colorSession: sessionButton.color
    property alias cfg_colorWeekly: weeklyButton.color
    property alias cfg_colorWarning: warningButton.color
    property alias cfg_colorCritical: criticalButton.color
    property alias cfg_colorText: textButton.color

    // ── Bar Colors: the two "normal" (sub-warning) fills, one per limit. ──────
    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Bar Colors")
    }
    KQControls.ColorButton {
        id: sessionButton
        Kirigami.FormData.label: i18n("Session bar:")
        showAlphaChannel: false
    }
    KQControls.ColorButton {
        id: weeklyButton
        Kirigami.FormData.label: i18n("Weekly bar:")
        showAlphaChannel: false
    }

    // ── Warning Colors: shared, applied once a bar crosses its threshold. ─────
    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Warning Colors")
    }
    KQControls.ColorButton {
        id: warningButton
        Kirigami.FormData.label: i18n("Warning color:")
        showAlphaChannel: false
    }
    KQControls.ColorButton {
        id: criticalButton
        Kirigami.FormData.label: i18n("Critical color:")
        showAlphaChannel: false
    }

    // ── Text Color: the panel label (countdown + percentage). ────────────────
    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Text Color")
    }
    KQControls.ColorButton {
        id: textButton
        Kirigami.FormData.label: i18n("Text color:")
        showAlphaChannel: false
    }

    Item { Kirigami.FormData.isSection: true }

    // Reset the five color values back to the classic palette. Assigning to a
    // cfg_ alias writes through to the bound ColorButton, which Plasma persists
    // like any manual edit.
    QQC2.Button {
        text: i18n("Reset to defaults")
        onClicked: {
            cfg_colorSession  = "#8fff8f"
            cfg_colorWeekly   = "#23a8fa"
            cfg_colorWarning  = "#ffaa44"
            cfg_colorCritical = "#ff5f5f"
            cfg_colorText     = "#ffffff"
        }
    }
}
