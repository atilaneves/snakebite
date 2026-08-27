Scripts that port guest snippets from quickbite. See
`ai/research-porting-quickbite-tests.md`.

    ./extract-snippets.py --quickbite ../quickbite/tests/ut/backends/runner \
        -o snippets.json

`astcover.d` goes into `tests/ut/` to write the AST node classes each
snippet reaches, then:

    ./cover-set.py -i snippets.json --nodes nodes.json \
        -m ut.backends.run -d tests/ut/backends/run

`port-snippet.py` ports the whole corpus instead of a cover set.
