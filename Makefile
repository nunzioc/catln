build:
	stack build --pedantic

format:
	find app -maxdepth 1 -name "*.hs" | xargs stylish-haskell -i