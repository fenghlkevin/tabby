import { Injectable } from '@angular/core'
import { TerminalColorSchemeProvider } from './api/colorSchemeProvider'
import { TerminalColorScheme } from 'tabby-core'

@Injectable({ providedIn: 'root' })
export class DefaultColorSchemes extends TerminalColorSchemeProvider {
    /** Initial palette extracted from the customized Dracula configuration. */
    static initialColorScheme: TerminalColorScheme = {
        name: 'Dracula Green',
        foreground: '#00CC74',
        background: '#1e1f29',
        cursor: '#bbbbbb',
        colors: [
            '#000000',
            '#ff5555',
            '#50fa7b',
            '#f1fa8c',
            '#bd93f9',
            '#ff79c6',
            '#8be9fd',
            '#bbbbbb',
            '#555555',
            '#ff5555',
            '#50fa7b',
            '#f1fa8c',
            '#bd93f9',
            '#ff79c6',
            '#8be9fd',
            '#ffffff',
        ],
    }

    static defaultColorScheme: TerminalColorScheme = {
        name: 'Tabby Default',
        foreground: '#cacaca',
        background: '#171717',
        cursor: '#bbbbbb',
        colors: [
            '#000000',
            '#ff615a',
            '#b1e969',
            '#ebd99c',
            '#5da9f6',
            '#e86aff',
            '#82fff7',
            '#dedacf',
            '#313131',
            '#f58c80',
            '#ddf88f',
            '#eee5b2',
            '#a5c7ff',
            '#ddaaff',
            '#b7fff9',
            '#ffffff',
        ],
    }

    static defaultLightColorScheme: TerminalColorScheme = {
        name: 'Tabby Default Light',
        foreground: '#4d4d4c',
        background: '#ffffff',
        cursor: '#4d4d4c',
        colors: [
            '#000000',
            '#c82829',
            '#718c00',
            '#eab700',
            '#4271ae',
            '#8959a8',
            '#3e999f',
            '#ffffff',
            '#000000',
            '#c82829',
            '#718c00',
            '#eab700',
            '#4271ae',
            '#8959a8',
            '#3e999f',
            '#ffffff',
        ],
    }

    async getSchemes (): Promise<TerminalColorScheme[]> {
        return [
            DefaultColorSchemes.initialColorScheme,
            DefaultColorSchemes.defaultColorScheme,
            DefaultColorSchemes.defaultLightColorScheme,
        ]
    }
}
