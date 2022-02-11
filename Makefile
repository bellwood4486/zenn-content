.PHONY: preview new upgrade

preview:
	npx zenn preview

upgrade:
	npm install zenn-cli@latest

new:
	npx zenn new:article
