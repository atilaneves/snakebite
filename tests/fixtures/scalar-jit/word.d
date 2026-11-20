private union Word {
    uint full;
    ushort firstHalf;
}

private uint updateWord(uint seed, ushort replacement, int count) {
    Word word = Word(seed);
    for (int i; i < count; ++i) {
        word.full += 0x1_0000;
        word.firstHalf = replacement;
    }
    return word.full;
}

void checkWord() {
    version (LittleEndian) {
        enum many = 0x312F_83CD;
        enum one = 0x3004_8AFE;
    } else {
        enum many = 0x83CD_7ABA;
        enum one = 0x8AFE_7ABA;
    }
    auto update = &updateWord;
    foreach (_; 0 .. 3)
        assert(update(0x3003_7ABA, 0x83CD, 300) == many);
    assert(update(0x3003_7ABA, 0x8AFE, 1) == one);
    assert(update(0x3003_7ABA, 0x8AFE, 0) == 0x3003_7ABA);
}
