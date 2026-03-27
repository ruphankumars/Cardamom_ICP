/**
 * Cardamom ICP Backend — Azle Server Entry Point
 *
 * Wraps the existing Express application inside Azle's experimental Server()
 * function to run as an ICP canister. This is the main entry point for the
 * backend canister.
 */

import { Server } from 'azle/experimental';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
import { initDatabase, getDatabase } from './database/sqliteClient';

export default Server(() => {
    const app = express();

    // ---------------------------------------------------------------------------
    // Middleware
    // ---------------------------------------------------------------------------
    app.use(express.json({ limit: '50mb' }));
    app.use(express.urlencoded({ extended: true, limit: '50mb' }));
    app.use(cors());
    app.use(compression());

    // Helmet with relaxed CSP for ICP
    app.use(helmet({
        contentSecurityPolicy: false,
        crossOriginEmbedderPolicy: false,
    }));

    // ---------------------------------------------------------------------------
    // Initialize SQLite database
    // ---------------------------------------------------------------------------
    initDatabase();

    // ---------------------------------------------------------------------------
    // Health Check
    // ---------------------------------------------------------------------------
    app.get('/health', (_req, res) => {
        const db = getDatabase();
        const dbStatus = db ? 'connected' : 'disconnected';
        res.json({
            status: 'ok',
            platform: 'icp',
            database: dbStatus,
            timestamp: new Date().toISOString(),
        });
    });

    // ---------------------------------------------------------------------------
    // API Info
    // ---------------------------------------------------------------------------
    app.get('/api/info', (_req, res) => {
        res.json({
            name: 'Cardamom ICP Backend',
            version: '1.0.0',
            platform: 'Internet Computer Protocol',
            database: 'SQLite (sql.js)',
            framework: 'Azle + Express',
        });
    });

    // ---------------------------------------------------------------------------
    // TODO: Mount route modules from converted Firebase modules
    // These will be added as each _fb.js module is converted to use sqliteClient
    //
    // Example (Phase 2+3):
    //   import { authRoutes } from './routes/auth';
    //   import { userRoutes } from './routes/users';
    //   app.use('/api/auth', authRoutes);
    //   app.use('/api/users', userRoutes);
    // ---------------------------------------------------------------------------

    // ---------------------------------------------------------------------------
    // 404 handler
    // ---------------------------------------------------------------------------
    app.use((_req, res) => {
        res.status(404).json({ error: 'Not found' });
    });

    return app.listen();
});
