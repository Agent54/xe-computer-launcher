import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('./authorize-macos-dialog.jxa', import.meta.url), 'utf8');
const fixturePassword = 'fixture-secret-must-never-appear-in-logs';

// Execute the actual JXA helper with a simulated System Events object model.
// No real credentials, authorization dialogs, or macOS settings are accessed.
function simulate(options = {}) {
    let clock = 100000;
    let visible = true;
    let focused = false;
    let frontmost = options.frontmost ?? false;
    let fieldValue = options.initialValue ?? 'partial entry';
    let submissions = 0;
    let physicalSubmissions = 0;
    const writes = [];
    const keys = [];
    const logs = [];
    const lookups = [];
    const passwordField = {
        role: () => 'AXTextField',
        subrole: () => 'AXSecureTextField',
        focused: () => focused,
        position: () => [100, 100],
        size: () => [200, 20],
        click: () => { focused = true; },
        set value(value) {
            if (options.rejectAXWrite) {
                const error = new Error('Cannot set secure field to ' + value);
                error.errorNumber = -10006;
                throw error;
            }
            fieldValue = value;
            writes.push(value);
        },
    };
    function submit() {
        submissions++;
        if (!options.keepPrompt) visible = false;
        if (options.submitThrows) throw new Error('Submit reply failed: ' + fixturePassword);
    }
    const button = {
        role: () => 'AXButton', subrole: () => '', name: () => 'Update Settings',
        position: () => [100, 150], size: () => [200, 30],
        click: () => { if (!options.ignoreAXClick) submit(); },
    };
    const text = {
        role: () => 'AXStaticText', subrole: () => '',
        value: () => options.context ?? 'security: You are making changes to your Certificate Trust Settings.',
    };
    const window = {
        name: () => 'security',
        performAction: () => {},
        entireContents: () => [text, ...(options.noSecureField ? [] : [passwordField]), button],
    };
    const owner = {
        exists: () => true,
        windows: () => visible ? [window] : [],
        click: ({at}) => {
            if (at[1] === 165) { physicalSubmissions++; submit(); }
            else focused = true;
        },
        get frontmost() { return () => frontmost; },
        set frontmost(value) { if (!options.blockActivation) frontmost = value; },
    };
    const events = {
        applicationProcesses: {
            byName(name) {
                lookups.push(name);
                if (options.brokenFirstOwner && name === 'SecurityAgent') {
                    return {exists: () => true, windows: () => {
                        const error = new Error(fixturePassword);
                        error.errorNumber = -1728;
                        throw error;
                    }};
                }
                return name === (options.owner ?? 'SecurityAgent') ? owner : {exists: () => false};
            },
        },
        keystroke(value, modifiers) {
            keys.push([value, modifiers]);
            if (options.typingThrows && value === fixturePassword) throw new Error('Typing failed: ' + value);
            if (value === 'a' && modifiers?.using === 'command down') fieldValue = '';
            else fieldValue += value;
        },
        keyCode: submit,
    };
    const environment = {
        XE_CI_MAC_PASSWORD: options.missingPassword ? null : fixturePassword,
        XE_CI_AUTH_KIND: options.authKind ?? 'certificate',
        XE_CI_CERT_PATH: '/fixture/root.crt',
    };
    const context = {
        ObjC: {import: () => {}, unwrap: value => value},
        $: {
            NSProcessInfo: {processInfo: {environment: {objectForKey: key => environment[key]}}},
            NSFileManager: {defaultManager: {fileExistsAtPath: () => !options.noCertificate}},
            NSThread: {sleepForTimeInterval: seconds => { clock += seconds * 1000; }},
        },
        Date: {now: () => clock},
        Application: () => {
            if (options.applicationThrows) throw new Error(fixturePassword);
            return events;
        },
        console: {log: value => logs.push(value)},
    };
    let result;
    let error;
    try { result = vm.runInNewContext(source + '\nrun();', context, {timeout: 2000}); }
    catch (caught) { error = caught; }
    assert.ok(!logs.join('\n').includes(fixturePassword), 'helper diagnostics leaked the password');
    assert.ok(!String(error?.message).includes(fixturePassword), 'helper error leaked the password');
    return {result, error, writes, keys, logs, lookups, submissions, physicalSubmissions, fieldValue};
}

const cases = {
    'writes directly to the matched secure field before using the keyboard'() {
        const result = simulate();
        assert.equal(result.error, undefined);
        assert.deepEqual(result.writes, [fixturePassword]);
        assert.deepEqual(result.keys, []);
        assert.equal(result.submissions, 1);
        assert.match(result.result, /dialog closed/);
    },
    'replaces an existing entry when AX assignment requires keyboard fallback'() {
        const result = simulate({rejectAXWrite: true});
        assert.equal(result.error, undefined);
        assert.equal(result.fieldValue, fixturePassword);
        assert.deepEqual(result.keys.map(([key]) => key), ['a', fixturePassword]);
        assert.equal(result.submissions, 1);
        assert.match(result.logs.join('\n'), /Apple Event error -10006/);
    },
    'sends no password keystrokes when the dialog cannot become frontmost'() {
        const result = simulate({rejectAXWrite: true, blockActivation: true});
        assert.match(result.error.message, /did not complete/);
        assert.deepEqual(result.keys, []);
        assert.equal(result.submissions, 0);
        assert.match(result.logs.join('\n'), /no password keystrokes sent/);
    },
    'continues after another authorization process raises an Apple Event error'() {
        const result = simulate({brokenFirstOwner: true, owner: 'AuthorizationHost'});
        assert.equal(result.error, undefined);
        assert.equal(result.submissions, 1);
        assert.match(result.logs.join('\n'), /Apple Event error -1728/);
    },
    'ignores unrelated Keychain and system-domain authorization prompts'() {
        for (const context of [
            'Helium wants to use your login Keychain.',
            'security: You are making changes to the System Certificate Trust Settings.',
        ]) {
            const result = simulate({context});
            assert.equal(result.submissions, 0);
            assert.deepEqual(result.writes, []);
            assert.deepEqual(result.keys, []);
        }
    },
    'reports a matched dialog that exposes no secure field'() {
        const result = simulate({noSecureField: true});
        assert.match(result.logs.join('\n'), /exposes no secure password field/);
        assert.equal(result.submissions, 0);
        assert.deepEqual(result.keys, []);
    },
    'bounds retries and clears the field before the second submission'() {
        const result = simulate({keepPrompt: true});
        assert.match(result.error.message, /remained open/);
        assert.equal(result.submissions, 2);
        assert.equal(result.fieldValue, fixturePassword);
        assert.deepEqual(result.keys.map(([key]) => key), ['a', fixturePassword]);
    },
    'bounds submissions when the AX click reply fails after delivery'() {
        const result = simulate({keepPrompt: true, submitThrows: true});
        assert.match(result.error.message, /remained open/);
        assert.equal(result.submissions, 2);
    },
    'retains the physical-click fallback when a protected panel ignores AX clicks'() {
        const result = simulate({ignoreAXClick: true});
        assert.equal(result.error, undefined);
        assert.equal(result.physicalSubmissions, 1);
        assert.equal(result.submissions, 1);
        assert.match(result.result, /dialog closed/);
    },
    'sanitizes exceptions from password typing and opening System Events'() {
        for (const options of [{rejectAXWrite: true, typingThrows: true}, {applicationThrows: true}]) {
            const result = simulate(options);
            assert.ok(result.error);
            assert.equal(result.submissions, 0);
        }
    },
    'fails clearly when no password secret was supplied'() {
        assert.match(simulate({missingPassword: true}).error.message, /has no password/);
    },
    'waits for the expected certificate before inspecting or filling a dialog'() {
        const result = simulate({noCertificate: true});
        assert.match(result.error.message, /did not complete/);
        assert.deepEqual(result.lookups, []);
        assert.deepEqual(result.writes, []);
    },
    'retains permission-dialog support for the full onboarding flow'() {
        const result = simulate({authKind: 'permission', context: 'Xe Launcher Accessibility', owner: 'System Settings', frontmost: true, initialValue: ''});
        assert.equal(result.submissions, 1);
        assert.equal(result.fieldValue, fixturePassword);
        assert.match(result.result, /matching macOS permission dialog/);
    },
};

for (const [name, test] of Object.entries(cases)) {
    test();
    console.log('PASS: ' + name);
}
