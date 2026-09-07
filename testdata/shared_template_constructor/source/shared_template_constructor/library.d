module shared_template_constructor.library;


public __gshared bool initialized;


public void initialize() nothrow {
    initialized = true;
}


public mixin template constructor() {
    shared static this() nothrow {
        initialize;
    }
}
