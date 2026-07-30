import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const MM_NAME = 'org.freedesktop.ModemManager1';
const MM_PATH = '/org/freedesktop/ModemManager1';
const MM_MODEM_IFACE = 'org.freedesktop.ModemManager1.Modem';

const NM_NAME = 'org.freedesktop.NetworkManager';
const NM_PATH = '/org/freedesktop/NetworkManager';

/* NMSettingConnection type strings whose icon the shell already draws as
 * cellular. Empty means no primary connection at all. */
const CELLULAR_CONNECTION_TYPES = ['gsm', 'cdma'];

/* MMModemAccessTechnology bits */
const TECH_5GNR = 1 << 15;
const TECH_LTE = 1 << 14;

/* Checked most-specific first. 5GNR and LTE are handled separately because it
 * is their combination that identifies EN-DC. */
const TECH_NAMES = [
    [1 << 9, 'H+'],
    [1 << 8, 'H+'],
    [1 << 7, 'H'],
    [1 << 6, 'H'],
    [1 << 5, '3G'],
    [1 << 4, 'E'],
    [1 << 3, 'G'],
    [1 << 2, '2G'],
    [1 << 1, '2G'],
];

/* MMModemState */
const STATE_REGISTERED = 8;

function techLabel(bits) {
    /* 5GNR with an LTE anchor is EN-DC (non-standalone). 5GNR alone means the
     * modem registered against a 5G core, which materially changes the carrier
     * bandwidth available, so the two are worth distinguishing. */
    if (bits & TECH_5GNR)
        return bits & TECH_LTE ? '5G' : '5G SA';
    if (bits & TECH_LTE)
        return 'LTE';

    for (const [bit, name] of TECH_NAMES) {
        if (bits & bit)
            return name;
    }
    return '';
}

/* Same thresholds the shell uses for its own cellular icon, so this indicator
 * and the built-in one never disagree about signal strength. */
function signalToIcon(value) {
    if (value < 20)
        return 'none';
    else if (value < 40)
        return 'weak';
    else if (value < 50)
        return 'ok';
    else if (value < 80)
        return 'good';
    else
        return 'excellent';
}

export default class CellularTechExtension extends Extension {
    enable() {
        this._modems = new Map();
        this._signalIds = [];
        this._nmSignalIds = [];
        this._primaryType = '';

        this._box = new St.BoxLayout({
            style_class: 'panel-status-indicators-box cellular-tech-box',
            visible: false,
        });
        this._icon = new St.Icon({style_class: 'system-status-icon'});
        this._label = new St.Label({
            style_class: 'cellular-tech-label',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._box.add_child(this._icon);
        this._box.add_child(this._label);

        this._placeIndicator();

        this._bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, null);
        this._watchPrimaryConnection();
        this._nameWatchId = Gio.bus_watch_name(
            Gio.BusType.SYSTEM, MM_NAME, Gio.BusNameWatcherFlags.NONE,
            () => this._modemManagerAppeared(),
            () => this._modemManagerVanished());
    }

    /* The shell draws one icon, for whichever connection NetworkManager reports
     * as primary. Asking NetworkManager which type that is answers "will the
     * shell already be showing cellular bars?" from the same source the shell
     * binds its own indicator to, without reading its internals. */
    _watchPrimaryConnection() {
        this._nmSignalIds.push(this._bus.signal_subscribe(
            NM_NAME, 'org.freedesktop.DBus.Properties', 'PropertiesChanged',
            NM_PATH, NM_NAME, Gio.DBusSignalFlags.NONE,
            (conn_, sender_, path_, iface_, signal_, params) => {
                const [, changed] = params.deepUnpack();
                if ('PrimaryConnectionType' in changed) {
                    this._primaryType = changed.PrimaryConnectionType.deepUnpack();
                    this._sync();
                }
            }));

        this._bus.call(
            NM_NAME, NM_PATH, 'org.freedesktop.DBus.Properties', 'Get',
            new GLib.Variant('(ss)', [NM_NAME, 'PrimaryConnectionType']),
            null, Gio.DBusCallFlags.NONE, -1, null,
            (bus, res) => {
                try {
                    const [value] = bus.call_finish(res).deepUnpack();
                    this._primaryType = value.deepUnpack();
                    this._sync();
                } catch (e) {
                    console.warn(`cellular-tech: primary connection type: ${e.message}`);
                }
            });
    }

    disable() {
        if (this._nameWatchId) {
            Gio.bus_unwatch_name(this._nameWatchId);
            this._nameWatchId = 0;
        }
        this._unsubscribe();
        for (const id of this._nmSignalIds ?? [])
            this._bus?.signal_unsubscribe(id);
        this._nmSignalIds = [];

        this._box?.destroy();
        this._box = null;
        this._icon = null;
        this._label = null;
        this._modems = null;
        this._bus = null;
    }

    /* Sit immediately beside the network indicator so the modem reads as part of
     * the network status rather than as an unrelated tray item. */
    _placeIndicator() {
        const quickSettings = Main.panel.statusArea.quickSettings;
        const box = quickSettings?._indicators;
        if (!box)
            return;

        /* Sit immediately after the network indicator. Bars then technology has
         * to hold in both cases, and when cellular is primary the bars being
         * shown are the shell's own, drawn from that indicator -- so placing
         * ahead of it would put the label on the wrong side of them.
         *
         * set_child_above_sibling() rather than an index: it says "directly
         * after this actor" without depending on where the actor sits. */
        const network = quickSettings._network;
        box.add_child(this._box);
        if (network)
            box.set_child_above_sibling(this._box, network);

        console.debug(`cellular-tech: indicator order: ${
            box.get_children()
                .map(c => (c === this._box ? '<self>'
                    : c === network ? '<network>'
                    : c.constructor?.name ?? 'actor'))
                .join(' ')}`);
    }

    _unsubscribe() {
        for (const id of this._signalIds ?? [])
            this._bus?.signal_unsubscribe(id);
        this._signalIds = [];
    }

    _modemManagerAppeared() {
        /* The object path is deliberately unfiltered: modems are re-enumerated
         * (Modem/0 -> Modem/1 ...) on every power cycle, SIM slot switch and
         * resume, so subscribing per-path would go stale. */
        this._signalIds.push(this._bus.signal_subscribe(
            MM_NAME, 'org.freedesktop.DBus.Properties', 'PropertiesChanged',
            null, MM_MODEM_IFACE, Gio.DBusSignalFlags.NONE,
            (conn_, sender_, path, iface_, signal_, params) => {
                const [, changed] = params.deepUnpack();
                this._updateModem(path, changed);
            }));

        this._signalIds.push(this._bus.signal_subscribe(
            MM_NAME, 'org.freedesktop.DBus.ObjectManager', 'InterfacesAdded',
            MM_PATH, null, Gio.DBusSignalFlags.NONE,
            (conn_, sender_, path_, iface_, signal_, params) => {
                const [objectPath, interfaces] = params.deepUnpack();
                if (MM_MODEM_IFACE in interfaces)
                    this._updateModem(objectPath, interfaces[MM_MODEM_IFACE]);
            }));

        this._signalIds.push(this._bus.signal_subscribe(
            MM_NAME, 'org.freedesktop.DBus.ObjectManager', 'InterfacesRemoved',
            MM_PATH, null, Gio.DBusSignalFlags.NONE,
            (conn_, sender_, path_, iface_, signal_, params) => {
                const [objectPath, interfaces] = params.deepUnpack();
                if (interfaces.includes(MM_MODEM_IFACE)) {
                    this._modems.delete(objectPath);
                    this._sync();
                }
            }));

        this._listModems();
    }

    _modemManagerVanished() {
        this._unsubscribe();
        this._modems.clear();
        this._sync();
    }

    _listModems() {
        this._bus.call(
            MM_NAME, MM_PATH, 'org.freedesktop.DBus.ObjectManager',
            'GetManagedObjects', null, null,
            Gio.DBusCallFlags.NONE, -1, null,
            (bus, res) => {
                let objects;
                try {
                    [objects] = bus.call_finish(res).deepUnpack();
                } catch (e) {
                    console.warn(`cellular-tech: listing modems failed: ${e.message}`);
                    return;
                }
                for (const [path, interfaces] of Object.entries(objects)) {
                    if (MM_MODEM_IFACE in interfaces)
                        this._updateModem(path, interfaces[MM_MODEM_IFACE]);
                }
            });
    }

    _updateModem(path, properties) {
        const modem = this._modems.get(path) ?? {tech: 0, state: -1, quality: 0};

        if ('AccessTechnologies' in properties)
            modem.tech = properties.AccessTechnologies.deepUnpack();
        if ('State' in properties)
            modem.state = properties.State.deepUnpack();
        if ('SignalQuality' in properties)
            [modem.quality] = properties.SignalQuality.deepUnpack();

        this._modems.set(path, modem);
        this._sync();
    }

    _sync() {
        if (!this._box)
            return;

        /* Drawn only while a data connection is up or being built: strictly
         * above REGISTERED. A modem left merely registered -- cellular switched
         * off in quick settings, or no connection profile active -- carries no
         * traffic, and drawing it would keep a meaningless signal icon in the
         * panel indefinitely.
         *
         * Several modem objects can be present at once while one is being torn
         * down, so prefer the furthest along. */
        let active = null;
        for (const modem of this._modems.values()) {
            if (modem.state <= STATE_REGISTERED)
                continue;
            if (!active || modem.state > active.state)
                active = modem;
        }

        if (!active) {
            this._box.visible = false;
            return;
        }

        this._icon.icon_name =
            `network-cellular-signal-${signalToIcon(active.quality)}-symbolic`;
        this._label.text = techLabel(active.tech);

        /* Only the bars are suppressed when the shell is already drawing
         * cellular for the primary connection. The technology label stays: it is
         * most wanted precisely when cellular is the connection in use, and the
         * shell never renders it. */
        const primaryIsCellular =
            CELLULAR_CONNECTION_TYPES.includes(this._primaryType);

        this._icon.visible = !primaryIsCellular;
        this._label.visible = this._label.text !== '';
        this._box.visible = this._icon.visible || this._label.visible;
    }
}
