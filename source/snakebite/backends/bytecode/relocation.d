module snakebite.backends.bytecode.relocation;

private:

public import snakebite.relocation;

// Thread-local policy: recording must not change other compiler users.
public bool recordRelocs;
