# hibernado - Development Commands

default:
    just --list

build:
    .vscode/build.sh

test:
    .vscode/build.sh && scp out/Hibernado.zip deck@steamdeck.local:~ && clear && ssh deck@steamdeck.local 'journalctl --follow'

clean:
    rm -rf out
    rm -rf dist
    rm -rf node_modules
    rm -rf .rollup.cache

watch:
    ssh deck@steamdeck.local 'journalctl --follow'

ssh:
    ssh deck@steamdeck.local

send:
    scp out/Hibernado.zip deck@steamdeck.local:~ && clear && ssh deck@steamdeck.local 'journalctl --follow'