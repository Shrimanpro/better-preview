// FROZEN. Owned by the orchestrator.
// The built-in rc. It is parsed first; the user's ~/.config/better-preview/rc
// is applied on top. It also defines the rc grammar by example:
//
//   # comment
//   set <option> <value>
//   map [mode] <keys> <action> [argument]      (mode defaults to normal)
//   unmap [mode] <keys>
//   include <path>                              (relative to the including file)
//   theme-define <name> <dark|light>            (starts a theme block; the
//       following `set <color-key> <hex>` lines up to `theme-end` define it)
//   theme-end

public enum DefaultConfig {
    public static let userConfigPath = "~/.config/better-preview/rc"

    public static let rc = #"""
    # ---- Scrolling ----
    set scroll-step 80
    set scroll-hstep 80
    set smooth-scroll true
    set scroll-duration 0.16
    set scroll-page-overlap 0.1

    # ---- Zoom and layout ----
    set zoom-step 1.1
    set zoom-min 0.1
    set zoom-max 10
    set default-fit width
    set continuous true
    set dual-page false
    set dual-page-book true
    set page-padding 8

    # ---- Recolor and trim ----
    set recolor false
    set recolor-keephue false
    set trim-margins false
    set trim-padding 6

    # ---- Themes ----
    # "auto" follows the system appearance using theme-light / theme-dark.
    set theme auto
    set theme-light catppuccin-latte
    set theme-dark catppuccin-mocha

    # ---- Window ----
    set statusbar true
    set toolbar false
    set sidebar false
    set sidebar-width 180
    set font ""
    set font-size 12

    # ---- Keys and search ----
    set key-timeout 700
    set incremental-search true
    set search-wrap true
    set search-smartcase true

    # ---- Files ----
    set auto-reload true
    set synctex true
    set synctex-editor-command ""
    set ocr-languages ""
    set pdfkit-analysis false

    # ---- Normal mode ----
    map j scroll-down
    map k scroll-up
    map h scroll-left
    map l scroll-right
    map <Down> scroll-down
    map <Up> scroll-up
    map <Left> scroll-left
    map <Right> scroll-right
    map <C-e> scroll-down
    map <C-y> scroll-up
    map <C-d> scroll-half-down
    map <C-u> scroll-half-up
    map <C-f> scroll-page-down
    map <C-b> scroll-page-up
    map <Space> scroll-page-down
    map <S-Space> scroll-page-up
    map <PageDown> scroll-page-down
    map <PageUp> scroll-page-up
    map J page-next
    map K page-previous
    map gg goto-first
    map G goto-last
    map <Home> goto-first
    map <End> goto-last

    map + zoom-in
    map - zoom-out
    map = zoom-reset
    map zi zoom-in
    map zo zoom-out
    map z0 zoom-reset
    map a fit-page
    map s fit-width
    map r rotate-cw
    map d toggle-dual-page
    map c toggle-continuous
    map <C-r> toggle-recolor
    map t toggle-trim

    map / search-forward
    map ? search-backward
    map n search-next
    map N search-previous

    map m mark-set
    map ' mark-jump
    map ` mark-jump
    map <C-o> jump-back
    map <C-i> jump-forward

    map <Tab> toggle-sidebar
    map T toggle-toolbar
    map <C-n> toggle-statusbar
    map <F11> toggle-fullscreen
    map <F5> toggle-presentation
    map i toggle-inspector

    map : enter-command
    map <Esc> abort
    map o enter-command "open "
    map <Space>o open-palette
    map <C-p> open-palette
    map R reload
    map q close
    map ZZ close
    map ZQ quit

    # ---- Presentation mode ----
    map [presentation] j page-next
    map [presentation] k page-previous
    map [presentation] l page-next
    map [presentation] h page-previous
    map [presentation] <Space> page-next
    map [presentation] <S-Space> page-previous
    map [presentation] <Right> page-next
    map [presentation] <Left> page-previous
    map [presentation] <Down> page-next
    map [presentation] <Up> page-previous
    map [presentation] <PageDown> page-next
    map [presentation] <PageUp> page-previous
    map [presentation] gg goto-first
    map [presentation] G goto-last
    map [presentation] <C-r> toggle-recolor
    map [presentation] <Esc> toggle-presentation
    map [presentation] q toggle-presentation
    map [presentation] <F5> toggle-presentation
    """#
}
