/* eslint-disable @typescript-eslint/explicit-module-boundary-types */
import { Component, Injector } from '@angular/core'
import { TranslateService } from '@ngx-translate/core'
import { BaseTabComponent } from './baseTab.component'
import { ConfigService } from '../services/config.service'
import { LocaleService } from '../services/locale.service'

/** @hidden */
@Component({
    selector: 'welcome-page',
    templateUrl: './welcomeTab.component.pug',
    styleUrls: ['./welcomeTab.component.scss'],
})
export class WelcomeTabComponent extends BaseTabComponent {
    enableGlobalHotkey = false
    allLanguages = LocaleService.allLanguages

    constructor (
        public config: ConfigService,
        public locale: LocaleService,
        translate: TranslateService,
        injector: Injector,
    ) {
        super(injector)
        this.enableGlobalHotkey = (config.store.hotkeys['toggle-window']?.length ?? 0) > 0
        this.setTitle(translate.instant('Welcome'))
    }

    async closeAndDisable () {
        this.config.store.enableWelcomeTab = false
        this.config.store.pluginBlacklist = []
        if (!this.enableGlobalHotkey) {
            this.config.store.hotkeys['toggle-window'] = []
        } else if (!this.config.store.hotkeys['toggle-window']?.length) {
            this.config.store.hotkeys['toggle-window'] = ['Ctrl-Space']
        }
        await this.config.save()
        this.destroy()
    }
}
