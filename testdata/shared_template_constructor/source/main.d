module shared_template_constructor.main;


import shared_template_constructor.library;


mixin constructor!();


int main() {
    return initialized ? 0 : 1;
}
