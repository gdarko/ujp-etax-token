// KIBSTrust IDPrime token: give the CA certificates their own label and ID.
//
// New KIBSTrust tokens store Root CA G2, Qseal CA G3 and Qsig CA G3 with the
// same CKA_LABEL / CKA_ID as the user's private key. The UJP e-Danoci applet
// then pairs the key with a CA certificate and UJP answers "ÐŸÐ¾Ñ‚Ð¿Ð¸ÑÐ¾Ñ‚ Ð½Ðµ Ðµ Ð²Ð°Ñˆ".
//
// Modes (run through Fix-TokenIds.ps1, or with the 32-bit Java jjs.exe):
//   check   list the token and show what would change. No PIN, no changes.
//   apply   back up, then relabel the CA certificates. Asks for the PIN.
//   undo    restore the original label and ID from the backup. Asks for the PIN.
//
// The user certificate and the private key are never modified.

// 32-bit IDPrime PKCS#11 library, the same one the applet uses through gclib.dll
var MODULE = ["C:/Program Files (x86)/Gemalto/IDGo 800 PKCS#11/IDPrimePKCS11.dll",
              "C:/Program Files/SafeNet/Authentication/SAC/x32/IDPrimePKCS11.dll"]
    .filter(function (p) { return new java.io.File(p).exists(); })[0];
if (!MODULE) { print("No 32-bit IDPrimePKCS11.dll found. Install SAC and IDGo 800 PKCS#11."); exit(2); }
var BACKUP_DIR = java.lang.System.getProperty("user.home") + "/Documents/KIBSTrust-token-fix/backup";
var BACKUP     = BACKUP_DIR + "/backup.json";

var W = Packages.sun.security.pkcs11.wrapper;
var CK_ATTRIBUTE = Java.type("sun.security.pkcs11.wrapper.CK_ATTRIBUTE");
var Files = java.nio.file.Files, Paths = java.nio.file.Paths;
var Hex = javax.xml.bind.DatatypeConverter;

var CKA_CLASS = 0x0, CKA_LABEL = 0x3, CKA_VALUE = 0x11, CKA_ID = 0x102;
var CKO_CERTIFICATE = 1, CKU_USER = 1;
var CKF_RW_SESSION = 0x2, CKF_SERIAL_SESSION = 0x4;
var CKF_USER_PIN_COUNT_LOW = 0x10000, CKF_USER_PIN_FINAL_TRY = 0x20000, CKF_USER_PIN_LOCKED = 0x40000;

var mode = (arguments.length > 0 ? arguments[0] : "check").toLowerCase();
if (["check", "apply", "undo"].indexOf(mode) < 0) { print("Usage: check | apply | undo"); exit(2); }

// ---------------------------------------------------------------------------
function attr(type, value) {
    var a = new CK_ATTRIBUTE(type);
    if (value !== undefined) a.pValue = value;
    return a;
}
function attrs(list) { return Java.to(list, "sun.security.pkcs11.wrapper.CK_ATTRIBUTE[]"); }
function hex(bytes) { return bytes ? Hex.printHexBinary(bytes) : ""; }
function ascii(s) { return new java.lang.String(s).getBytes("US-ASCII"); }
function cn(name) { var m = /CN=([^,]+)/.exec(name); return m ? m[1] : name; }

function readCerts(p11, h) {
    p11.C_FindObjectsInit(h, attrs([attr(CKA_CLASS, new java.lang.Long(CKO_CERTIFICATE))]));
    var handles = p11.C_FindObjects(h, 50);
    p11.C_FindObjectsFinal(h);
    var cf = java.security.cert.CertificateFactory.getInstance("X.509");
    var out = [];
    for (var i = 0; i < handles.length; i++) {
        var t = attrs([attr(CKA_LABEL), attr(CKA_ID), attr(CKA_VALUE)]);
        p11.C_GetAttributeValue(h, handles[i], t);
        var der = t[2].pValue;
        var c = cf.generateCertificate(new java.io.ByteArrayInputStream(der));
        out.push({
            handle:  handles[i],
            label:   t[0].pValue ? String(new java.lang.String(t[0].pValue)) : "",
            idHex:   hex(t[1].pValue),
            der:     der,
            sha1:    hex(java.security.MessageDigest.getInstance("SHA-1").digest(der)),
            subject: String(c.getSubjectX500Principal().getName()),
            serial:  String(c.getSerialNumber()),
            isCA:    c.getBasicConstraints() >= 0
        });
    }
    return out;
}

function show(certs) {
    certs.forEach(function (c, i) {
        print("  [" + (i + 1) + "] " + cn(c.subject) + (c.isCA ? "  (CA)" : "  (YOUR CERTIFICATE)"));
        print("      label: " + c.label + "   id: " + c.idHex + " (\"" + new java.lang.String(Hex.parseHexBinary(c.idHex), "US-ASCII") + "\")");
        print("      serial: " + c.serial);
    });
}

function readPin() {
    var con = java.lang.System.console();
    if (con == null) { print("No console. Run this from a PowerShell window, not from another program."); exit(2); }
    var pin = con.readPassword("Token PIN: ");
    if (pin == null || pin.length == 0) { print("No PIN entered. Nothing changed."); exit(2); }
    return pin;
}

function confirm(question) {
    var con = java.lang.System.console();
    if (con == null) { print("No console. Run this from a PowerShell window, not from another program."); exit(2); }
    var answer = con.readLine(question + " Type YES to continue: ");
    return answer != null && String(answer).trim() === "YES";
}

function pinWarning(ti) {
    if (ti.flags & CKF_USER_PIN_LOCKED)    { print("The token PIN is LOCKED. Stop here and contact KIBSTrust."); exit(2); }
    if (ti.flags & CKF_USER_PIN_FINAL_TRY) print("WARNING: one PIN attempt left. A wrong PIN now locks the token.");
    else if (ti.flags & CKF_USER_PIN_COUNT_LOW) print("WARNING: a wrong PIN was entered before. Few attempts are left.");
}

function setLabelAndId(p11, h, handle, label, idBytes) {
    p11.C_SetAttributeValue(h, handle, attrs([
        attr(CKA_LABEL, new java.lang.String(label).toCharArray()),
        attr(CKA_ID, idBytes)
    ]));
}

// ---------------------------------------------------------------------------
var p11 = W.PKCS11.getInstance(MODULE, "C_GetFunctionList", null, false);
var slots = p11.C_GetSlotList(true);
if (slots.length != 1) { print("Expected exactly one token, found " + slots.length + ". Plug in only the KIBSTrust token."); exit(2); }
var ti = p11.C_GetTokenInfo(slots[0]);
print("Token: " + new java.lang.String(ti.label).trim());

var h = p11.C_OpenSession(slots[0], CKF_SERIAL_SESSION | (mode == "check" ? 0 : CKF_RW_SESSION), null, null);
var loggedIn = false;
try {
    var certs = readCerts(p11, h);
    print("Certificates on the token now:");
    show(certs);

    var users = certs.filter(function (c) { return !c.isCA; });
    if (users.length != 1) { print("Expected exactly one personal certificate, found " + users.length + ". Not touching anything."); exit(2); }
    var user = users[0];

    if (mode == "check" || mode == "apply") {
        var targets = certs.filter(function (c) {
            return c.isCA && c.sha1 != user.sha1 && /^KIBSTrust /.test(cn(c.subject)) &&
                   (c.idHex == user.idHex || c.label == user.label);
        });
        var plan = targets.map(function (c) {
            return { sha1: c.sha1, subject: c.subject, serial: c.serial,
                     oldLabel: c.label, oldIdHex: c.idHex,
                     newLabel: cn(c.subject), newIdHex: hex(ascii("CA-" + c.sha1.substring(0, 8))) };
        });
        print("");
        if (plan.length == 0) { print("Nothing to change: no CA certificate shares the label or ID of your certificate."); exit(0); }
        print("Planned changes (your certificate \"" + cn(user.subject) + "\" and its key stay as they are):");
        plan.forEach(function (p) {
            print("  " + cn(p.subject) + ": label " + p.oldLabel + " -> " + p.newLabel +
                  ", id " + p.oldIdHex + " -> " + p.newIdHex);
        });
        if (mode == "check") { print("\nCheck only. Nothing was changed."); exit(0); }

        // Backup first. An existing backup is kept, never overwritten.
        Files.createDirectories(Paths.get(BACKUP_DIR));
        if (Files.exists(Paths.get(BACKUP))) {
            var keep = BACKUP_DIR + "/backup-" + java.lang.System.currentTimeMillis() + ".json";
            Files.move(Paths.get(BACKUP), Paths.get(keep));
            print("Previous backup kept as " + keep);
        }
        targets.forEach(function (c) { Files.write(Paths.get(BACKUP_DIR + "/" + c.sha1 + ".cer"), c.der); });
        Files.write(Paths.get(BACKUP), ascii(JSON.stringify({ token: String(new java.lang.String(ti.label).trim()),
                                                              user: { subject: user.subject, sha1: user.sha1 },
                                                              changes: plan }, null, 2)));
        print("Backup written to " + BACKUP_DIR);

        print("");
        if (!confirm("Relabel " + plan.length + " CA certificate(s) on the token?")) { print("Cancelled. Nothing changed."); exit(0); }
        pinWarning(ti);
        p11.C_Login(h, CKU_USER, readPin());
        loggedIn = true;
        plan.forEach(function (p) {
            var c = targets.filter(function (t) { return t.sha1 == p.sha1; })[0];
            setLabelAndId(p11, h, c.handle, p.newLabel, Hex.parseHexBinary(p.newIdHex));
            print("  changed: " + cn(p.subject));
        });
    } else {
        if (!Files.exists(Paths.get(BACKUP))) { print("No backup found at " + BACKUP + ". Nothing to undo."); exit(2); }
        var backup = JSON.parse(new java.lang.String(Files.readAllBytes(Paths.get(BACKUP)), "UTF-8"));
        var todo = backup.changes.map(function (b) {
            var c = certs.filter(function (x) { return x.sha1 == b.sha1; })[0];
            return { b: b, c: c };
        }).filter(function (x) { return x.c && (x.c.label != x.b.oldLabel || x.c.idHex != x.b.oldIdHex); });
        var missing = backup.changes.filter(function (b) { return !certs.some(function (x) { return x.sha1 == b.sha1; }); });
        missing.forEach(function (b) { print("Not on the token any more: " + cn(b.subject) + " (copy in " + BACKUP_DIR + "/" + b.sha1 + ".cer)"); });
        print("");
        if (todo.length == 0) { print("Nothing to undo: the token already has the original labels and IDs."); exit(0); }
        todo.forEach(function (x) {
            print("  " + cn(x.b.subject) + ": label " + x.c.label + " -> " + x.b.oldLabel + ", id " + x.c.idHex + " -> " + x.b.oldIdHex);
        });
        if (!confirm("Restore the original label and ID?")) { print("Cancelled. Nothing changed."); exit(0); }
        pinWarning(ti);
        p11.C_Login(h, CKU_USER, readPin());
        loggedIn = true;
        todo.forEach(function (x) {
            setLabelAndId(p11, h, x.c.handle, x.b.oldLabel, Hex.parseHexBinary(x.b.oldIdHex));
            print("  restored: " + cn(x.b.subject));
        });
    }

    print("\nCertificates on the token after the change:");
    show(readCerts(p11, h));
    print("\nDone. Unplug and replug the token, close Firefox 52 completely, then sign again.");
} catch (e) {
    print("\nERROR: " + e);
    print("Stopped. Anything not listed as changed/restored above was not modified.");
    print("Run 'check' to see the current state of the token.");
} finally {
    if (loggedIn) { try { p11.C_Logout(h); } catch (ignored) {} }
    try { p11.C_CloseSession(h); } catch (ignored) {}
}
