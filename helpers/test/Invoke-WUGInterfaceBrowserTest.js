'use strict';

const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

function option(name) {
    const index = process.argv.indexOf(name);
    return index < 0 ? null : process.argv[index + 1];
}

function loadPlaywright() {
    const modulePath = option('--playwright-module');
    if (modulePath) {
        const resolved = path.resolve(modulePath);
        if (!fs.existsSync(resolved)) {
            throw new Error(`Playwright module path does not exist: ${resolved}`);
        }
        return require(resolved);
    }

    for (const name of ['playwright', 'playwright-core']) {
        try {
            return require(name);
        } catch (error) {
            if (error.code !== 'MODULE_NOT_FOUND' || !error.message.includes(`'${name}'`)) {
                throw error;
            }
        }
    }
    throw new Error(
        'Playwright is not installed or resolvable by Node.js. Bootstrap without editing package manifests with ' +
        '`npm install --no-save --package-lock=false playwright`, then run `npx playwright install chromium`; ' +
        'or provide -PlaywrightModulePath and -BrowserExecutablePath.'
    );
}

function assert(condition, message) {
    if (!condition) {
        throw new Error(message);
    }
}

function expectEqual(expected, actual, message) {
    if (expected !== actual) {
        throw new Error(`${message}; expected '${expected}', got '${actual}'`);
    }
}

async function waitForRowCount(page, count) {
    await page.waitForFunction(expected => {
        return document.querySelectorAll('#table tbody tr[data-index]').length === expected;
    }, count, { timeout: 10000 });
}

async function run() {
    const dashboardPath = option('--dashboard');
    const reviewPath = option('--review');
    assert(dashboardPath && fs.existsSync(dashboardPath), 'Generated interface dashboard was not found.');
    assert(reviewPath && fs.existsSync(reviewPath), 'Generated graphical review page was not found.');

    const { chromium } = loadPlaywright();
    assert(chromium, 'The resolved Playwright package does not expose Chromium.');
    const browserExecutablePath = option('--browser-executable');
    if (browserExecutablePath && !fs.existsSync(browserExecutablePath)) {
        throw new Error(`Browser executable path does not exist: ${browserExecutablePath}`);
    }

    const launchOptions = { headless: true };
    if (browserExecutablePath) {
        launchOptions.executablePath = path.resolve(browserExecutablePath);
    }

    const externalRequests = [];
    const pageErrors = [];
    const browser = await chromium.launch(launchOptions);
    try {
        const context = await browser.newContext({ serviceWorkers: 'block' });
        await context.route('**/*', async route => {
            const url = route.request().url();
            const protocol = new URL(url).protocol;
            if (['file:', 'data:', 'blob:', 'about:'].includes(protocol)) {
                await route.continue();
                return;
            }
            externalRequests.push(url);
            await route.abort();
        });

        const dashboard = await context.newPage();
        dashboard.on('pageerror', error => pageErrors.push(`dashboard: ${error.message}`));
        dashboard.on('request', request => {
            const protocol = new URL(request.url()).protocol;
            if (!['file:', 'data:', 'blob:', 'about:'].includes(protocol) &&
                !externalRequests.includes(request.url())) {
                externalRequests.push(request.url());
            }
        });
        await dashboard.goto(pathToFileURL(path.resolve(dashboardPath)).href, { waitUntil: 'load' });
        await dashboard.waitForSelector('#interface-chart circle[role="img"]', { timeout: 10000 });
        await waitForRowCount(dashboard, 3);
        expectEqual('Showing 3 rows', (await dashboard.locator('#rowCounter').innerText()).trim(),
            'Dashboard fixture should expose three rows');
        console.log('PASS: offline dashboard loads the deterministic fixture');

        const search = dashboard.locator('.fixed-table-toolbar .search input');
        await search.click();
        await search.type('eth2', { delay: 10 });
        await dashboard.waitForFunction(() => {
            const counter = document.querySelector('#rowCounter');
            return counter && counter.textContent.includes('Showing 1 of 3 rows');
        }, null, { timeout: 10000 });
        const filteredRows = await dashboard.locator('#table tbody tr[data-index]').allInnerTexts();
        expectEqual(1, filteredRows.length, 'Key-up search should leave one dashboard row');
        assert(filteredRows[0].includes('eth2'), 'The filtered row does not match the typed interface.');
        console.log('PASS: dashboard search filters on typed key events');

        await search.fill('');
        await dashboard.waitForFunction(() => {
            const counter = document.querySelector('#rowCounter');
            return counter && counter.textContent.includes('Showing 3 rows');
        }, null, { timeout: 10000 });
        const keyHeader = dashboard.locator('#table thead tr:last-child th[data-field="InterfaceKey"]');
        await keyHeader.click();
        await keyHeader.click();
        const sortedKeys = await dashboard.locator('#table tbody tr[data-index]').evaluateAll(rows =>
            rows.map(row => {
                const cell = row.querySelector('td[data-field="InterfaceKey"]') || row.cells[0];
                return cell.textContent.trim();
            })
        );
        const ascending = sortedKeys.every((key, index) => index === 0 || sortedKeys[index - 1].localeCompare(key) <= 0);
        const descending = sortedKeys.every((key, index) => index === 0 || sortedKeys[index - 1].localeCompare(key) >= 0);
        assert(ascending || descending, `InterfaceKey column did not sort rows: ${sortedKeys.join(', ')}`);
        await dashboard.getByText('818:3', { exact: true }).click();
        expectEqual('818:3', await dashboard.locator('#interface-choice').inputValue(),
            'Selecting a sorted row should resolve its InterfaceKey');
        console.log('PASS: sorted table-row selection resolves by InterfaceKey');

        await dashboard.locator('#interface-top-consumers button').first().click();
        expectEqual('818:2', await dashboard.locator('#interface-choice').inputValue(),
            'Top consumer selection should choose the highest-rate interface');
        const chart = dashboard.locator('#interface-chart');
        expectEqual('2', String(await chart.locator('polyline').count()), 'Traffic chart should draw RX and TX series');
        assert(await chart.locator('circle[role="img"][tabindex="0"]').count() >= 4,
            'Traffic chart should provide keyboard-focusable, labelled samples.');
        assert((await chart.getAttribute('aria-label')).includes('traffic history'),
            'Traffic chart is missing its accessible name.');
        console.log('PASS: top-consumer selection and accessible traffic chart');

        const interfaceSelect = dashboard.locator('#interface-choice');
        const interfaceOptions = await interfaceSelect.locator('option').evaluateAll(options =>
            options.map(option => option.value)
        );
        assert(interfaceOptions.length >= 2, 'The fixture needs multiple interfaces for keyboard selection.');
        await interfaceSelect.focus();
        await dashboard.keyboard.press('Home');
        await dashboard.keyboard.press('ArrowDown');
        await dashboard.keyboard.press('Enter');
        expectEqual(interfaceOptions[1], await interfaceSelect.inputValue(),
            'Keyboard selection should move to the second interface option');
        const mode = dashboard.locator('#interface-chart-mode');
        await mode.focus();
        await dashboard.keyboard.press('ArrowDown');
        await dashboard.keyboard.press('Enter');
        assert((await chart.getAttribute('aria-label')).includes('utilization history'),
            'Keyboard chart-mode selection did not update its accessible label.');
        assert((await chart.evaluate(element => element.textContent)).includes('Utilization (%)'),
            'Utilization chart did not render its axis label.');
        const point = chart.locator('circle[role="img"][tabindex="0"]').first();
        assert((await point.getAttribute('aria-label')).includes('RX'),
            'A chart point is missing its accessible value label.');
        await point.focus();
        assert((await dashboard.locator('#interface-hover').innerText()).includes('RX:'),
            'Keyboard focus on a chart point should announce its sample values.');
        console.log('PASS: keyboard interface/mode selection and chart-point accessibility');

        await dashboard.evaluate(() => {
            window.__wugBrowserTest = { csv: null, workbook: null };
            const originalSaveAs = window.saveAs;
            if (typeof originalSaveAs !== 'function') {
                throw new Error('FileSaver saveAs is not available.');
            }
            window.saveAs = function (blob, name) {
                if (/\.csv$/i.test(name)) {
                    window.__wugBrowserTest.csv = { blob, name };
                    return;
                }
                return originalSaveAs.apply(this, arguments);
            };
            const originalWriteFile = window.XLSX.writeFile;
            if (typeof originalWriteFile !== 'function') {
                throw new Error('SheetJS XLSX.writeFile is not available.');
            }
            window.XLSX.writeFile = function (workbook, name) {
                const sheet = workbook.Sheets.Data;
                const rows = window.XLSX.utils.sheet_to_json(sheet, { header: 1 });
                window.__wugBrowserTest.workbook = {
                    name,
                    rows,
                    base64: window.XLSX.write(workbook, { bookType: 'xlsx', type: 'base64' })
                };
            };
        });
        const exportButton = dashboard.locator('.dropdown-toggle').filter({ hasText: 'Export' });
        await exportButton.click();
        await dashboard.locator('.dropdown-item[data-type="csv"]').click();
        await dashboard.waitForFunction(() => window.__wugBrowserTest && window.__wugBrowserTest.csv);
        const csvCapture = await dashboard.evaluate(async () => {
            const capture = window.__wugBrowserTest.csv;
            const bytes = Array.from(new Uint8Array(await capture.blob.arrayBuffer()));
            return { name: capture.name, bytes };
        });
        const csv = { name: csvCapture.name, text: Buffer.from(csvCapture.bytes).toString('utf8') };
        assert(/\.csv$/i.test(csv.name), `CSV export used an unexpected filename: ${csv.name}`);
        const csvLines = csv.text.split('\r\n');
        const csvHeaders = csvLines[0].replace(/^\uFEFF/, '').split(',');
        for (const column of ['InterfaceKey', 'DeviceName', 'RxBps']) {
            assert(csvHeaders.includes(column), `CSV export is missing the '${column}' header.`);
        }
        expectEqual(4, csvLines.length, 'CSV export should contain a header and all three fixture rows');

        await exportButton.click();
        await dashboard.locator('.dropdown-item[data-type="xlsx"]').click();
        await dashboard.waitForFunction(() => window.__wugBrowserTest && window.__wugBrowserTest.workbook);
        const workbook = await dashboard.evaluate(() => window.__wugBrowserTest.workbook);
        assert(/\.xlsx$/i.test(workbook.name), `XLSX export used an unexpected filename: ${workbook.name}`);
        const workbookHeaders = workbook.rows[0] || [];
        for (const column of ['InterfaceKey', 'DeviceName', 'RxBps']) {
            assert(workbookHeaders.includes(column), `XLSX export is missing the '${column}' header.`);
        }
        expectEqual(4, workbook.rows.length, 'XLSX export should contain a header and all three fixture rows');
        const workbookBytes = Buffer.from(workbook.base64, 'base64');
        assert(workbookBytes.length > 0, 'Generated XLSX workbook is empty.');
        assert(workbookBytes[0] === 0x50 && workbookBytes[1] === 0x4b,
            'Generated XLSX workbook is not a ZIP-based Excel file.');
        console.log('PASS: CSV headers/rows and serialized XLSX workbook');

        const review = await context.newPage();
        review.on('pageerror', error => pageErrors.push(`review: ${error.message}`));
        await review.addInitScript(() => {
            window.__wugReviewDownload = null;
            const originalAnchorClick = HTMLAnchorElement.prototype.click;
            URL.createObjectURL = blob => {
                window.__wugReviewDownload = { blob, name: null };
                return 'blob:captured-review-download';
            };
            HTMLAnchorElement.prototype.click = function () {
                if (this.download) {
                    if (window.__wugReviewDownload) {
                        window.__wugReviewDownload.name = this.download;
                    }
                    return;
                }
                return originalAnchorClick.call(this);
            };
        });
        await review.goto(pathToFileURL(path.resolve(reviewPath)).href, { waitUntil: 'load' });
        await review.waitForSelector('#review-body tr');
        const reviewCounts = review.locator('#counts');
        expectEqual('status', await reviewCounts.getAttribute('role'), 'Review counts should expose a status role');
        expectEqual('polite', await reviewCounts.getAttribute('aria-live'), 'Review counts should announce updates');
        expectEqual('alert', await review.locator('#validation').getAttribute('role'),
            'Review validation should expose an alert role');
        assert(await review.locator('table caption').innerText().then(text => text.includes('all rows are included')),
            'Review table is missing its accessible caption.');
        await review.getByRole('button', { name: 'Download decisions CSV' }).click();
        assert((await review.locator('#validation').innerText()).includes('CSV download is blocked'),
            'Unmatched applied rows should prevent CSV download.');
        assert(await review.evaluate(() => window.__wugReviewDownload === null),
            'Invalid review unexpectedly created a CSV download.');
        console.log('PASS: graphical review blocks unapplied unmatched decisions accessibly');

        const reviewSearch = review.getByRole('searchbox', { name: 'Search inventory' });
        await reviewSearch.fill('818:9');
        await review.waitForFunction(() => {
            const visible = Array.from(document.querySelectorAll('#review-body tr')).filter(row => !row.hidden);
            return visible.length === 1;
        });
        const reviewSelect = review.getByRole('checkbox', { name: 'Select interface 818:9' });
        await reviewSelect.focus();
        await review.keyboard.press('Space');
        assert(await reviewSelect.isChecked(), 'Space should select the focused review row.');
        assert((await reviewCounts.innerText()).includes('1 selected'),
            'Keyboard review selection was not reflected in the live status.');
        await review.getByLabel("Selected rows' groups").fill('BrowserReviewed;Operations');
        await review.getByRole('button', { name: 'Assign selected' }).click();
        expectEqual('BrowserReviewed;Operations',
            await review.getByRole('textbox', { name: 'Groups for interface 818:9' }).inputValue(),
            'Bulk group assignment should update the selected row');
        await review.getByRole('button', { name: 'Preview decisions' }).click();
        assert((await review.locator('#preview').innerText()).includes('BrowserReviewed; Operations'),
            'Decision preview should show the edited group labels.');
        console.log('PASS: review filtering, keyboard row selection, editing and preview');

        await review.getByRole('button', { name: 'Download decisions CSV' }).click();
        const reviewCsvCapture = await review.evaluate(async () => {
            const capture = window.__wugReviewDownload;
            if (!capture || !capture.blob) return null;
            const bytes = Array.from(new Uint8Array(await capture.blob.arrayBuffer()));
            return { name: capture.name, bytes };
        });
        assert(reviewCsvCapture, 'Valid review decisions did not generate a CSV Blob.');
        const reviewCsv = {
            name: reviewCsvCapture.name,
            text: Buffer.from(reviewCsvCapture.bytes).toString('utf8')
        };
        expectEqual('interface-group-decisions.csv', reviewCsv.name, 'Review download filename changed');
        const expectedReviewHeaders = [
            'InterfaceKey', 'DeviceName', 'InterfaceComment', 'InterfaceName', 'IfAlias', 'IfName',
            'IfDescr', 'ProposedGroups', 'Groups', 'MatchExplanation', 'Exclude', 'Apply'
        ];
        const expectedHeaderLine = '\uFEFF' + expectedReviewHeaders.map(value => `"${value}"`).join(',');
        expectEqual(expectedHeaderLine, reviewCsv.text.split('\r\n')[0],
            'Review CSV schema/order must match the grouping importer');
        assert(reviewCsv.text.includes('"818:9"') &&
            reviewCsv.text.includes('"BrowserReviewed;Operations"'),
            'Review CSV did not include the edited row decision.');
        expectEqual(5, reviewCsv.text.split('\r\n').filter(Boolean).length,
            'Review CSV should include all four rows even while the table is filtered');
        console.log('PASS: review CSV schema, BOM, edited decision and all-row export');

        assert(externalRequests.length === 0,
            `Offline pages attempted external requests: ${externalRequests.join(', ')}`);
        assert(pageErrors.length === 0, `Browser page errors: ${pageErrors.join('; ')}`);
        console.log('PASS: zero external requests and zero page errors');
        await context.close();
    } finally {
        await browser.close();
    }
}

run().catch(error => {
    console.error(`FAIL: ${error && error.stack ? error.stack : error}`);
    process.exitCode = 1;
});
