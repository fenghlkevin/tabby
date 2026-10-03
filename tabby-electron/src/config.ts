import { ConfigProvider, Platform } from 'tabby-core'

/** @hidden */
export class ElectronConfigProvider extends ConfigProvider {
    platformDefaults = {
        [Platform.macOS]: {
            hotkeys: {
                'toggle-window': [],
                'new-window': ['⌘-N'],
            },
        },
        [Platform.Windows]: {
            hotkeys: {
                'toggle-window': [],
                'new-window': ['Ctrl-Shift-N'],
            },
        },
        [Platform.Linux]: {
            hotkeys: {
                'toggle-window': [],
                'new-window': ['Ctrl-Shift-N'],
            },
        },
    }

    defaults = {}
}
