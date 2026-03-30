#!/usr/bin/env node
/**
 * Upload cardamom.db to the ICP canister's import-db endpoint.
 *
 * Usage:
 *   node scripts/upload-db.js [path/to/cardamom.db]
 *
 * Defaults to data/cardamom.db
 * Target: mainnet backend canister ge6oz-5qaaa-aaaaj-qrraq-cai
 */

const https = require('https');
const fs = require('fs');
const path = require('path');

const dbPath = process.argv[2] || path.join(__dirname, '..', 'data', 'cardamom.db');
const CANISTER_ID = 'ge6oz-5qaaa-aaaaj-qrraq-cai';
const HOSTNAME = `${CANISTER_ID}.raw.icp0.io`;

if (!fs.existsSync(dbPath)) {
    console.error(`Error: Database file not found at ${dbPath}`);
    console.error('Run the import script first: node scripts/import-to-sqlite.js');
    process.exit(1);
}

const fileData = fs.readFileSync(dbPath);
console.log(`Uploading ${dbPath} (${(fileData.length / 1024).toFixed(1)} KB) to ${HOSTNAME}...`);

const options = {
    hostname: HOSTNAME,
    path: '/api/admin/system/import-db',
    method: 'POST',
    headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': fileData.length,
    },
    timeout: 120000,
};

const req = https.request(options, (res) => {
    let body = '';
    res.on('data', (chunk) => body += chunk);
    res.on('end', () => {
        console.log(`Status: ${res.statusCode}`);
        try {
            const parsed = JSON.parse(body);
            console.log('Response:', JSON.stringify(parsed, null, 2));
        } catch {
            console.log('Response:', body);
        }
        if (res.statusCode === 200) {
            console.log('\nDatabase uploaded successfully!');
        } else {
            console.error('\nUpload failed.');
            process.exit(1);
        }
    });
});

req.on('error', (err) => {
    console.error('Request error:', err.message);
    process.exit(1);
});

req.on('timeout', () => {
    console.error('Request timed out');
    req.destroy();
    process.exit(1);
});

req.write(fileData);
req.end();
