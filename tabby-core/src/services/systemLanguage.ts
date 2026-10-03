/** Match OS language tags (including script subtags) to bundled translations. */
export function resolveSystemLanguage (preferred: readonly string[], supported: readonly string[]): string {
    for (const language of preferred) {
        const tag = language.replace(/_/g, '-').toLowerCase()
        const exact = supported.find(x => x.toLowerCase() === tag)
        if (exact) {
            return exact
        }
        const parts = tag.split('-')
        if (parts[0] === 'zh') {
            const traditional = parts.includes('hant') || parts.includes('tw') || parts.includes('hk') || parts.includes('mo')
            const chinese = traditional ? 'zh-TW' : 'zh-CN'
            if (supported.includes(chinese)) {
                return chinese
            }
        }
        const regional = supported.find(x => x.toLowerCase() === parts.filter(part => part.length !== 4).join('-'))
        const fallback = supported.find(x => x.split('-')[0].toLowerCase() === parts[0])
        if (regional ?? fallback) {
            return regional ?? fallback!
        }
    }
    return 'en-US'
}
