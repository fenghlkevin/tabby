#!/usr/bin/env node
import * as vars from './vars.mjs'
import log from 'npmlog'
import webpack from 'webpack'
import { promisify } from 'node:util'
import fs from 'node:fs'

// Development launches read this metadata; installers use the same Git version.
const appManifestPath = new URL('../app/package.json', import.meta.url)
const appManifest = JSON.parse(fs.readFileSync(appManifestPath, 'utf8'))
if (appManifest.version !== vars.version) {
    appManifest.version = vars.version
    fs.writeFileSync(appManifestPath, JSON.stringify(appManifest, null, 2) + '\n')
}

const configs = [
    '../app/webpack.config.main.mjs',
    '../app/webpack.config.mjs',
    ...vars.allPackages.map(x => `../${x}/webpack.config.mjs`),
];

(async () => {
    try {
        for (const c of configs) {
            log.info('build', c)
            const stats = await promisify(webpack)((await import(c)).default())
            console.log(stats.toString({ colors: true }))
            if (stats.hasErrors()) {
                process.exit(1)
            }
        }
    } catch (error) {
        log.error('build', String(error))
        process.exit(1)
    }
})()
