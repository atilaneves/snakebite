module at.runtime.observedloop;

import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot slice a pointer to a scalar"),
)) {
    @("bufferUpdatesPreserveChecksumAcrossRepeatedAndOverlappingPasses."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(backend, q{
            struct Buffer {
                int[] slots;
                int checksum;

                void transform(int repetitions, int slot) {
                    for (int pass; pass < repetitions; ++pass) {
                        if (slot != 0)
                            return;
                        const first = slots[slot];
                        if (first == int.max)
                            return;
                        static foreach (delta; 1 .. 17) {
                            slots[slot] = delta + 1;
                            checksum += delta;
                        }
                    }
                }
            }

            bool result() {
                enum passes = 30;
                enum batches = 12;
                auto buffer = new Buffer;
                buffer.slots = new int[1];
                foreach (batch; 0 .. batches)
                    buffer.transform(passes, 0);
                if (buffer.slots[0] != 17 || buffer.checksum != batches * passes * 136)
                    return false;

                // Each slot assignment now changes the checksum before
                // the next addition reads it.
                buffer.slots = (&buffer.checksum)[0 .. 1];
                buffer.transform(passes, 0);
                return buffer.slots[0] == 33 && buffer.checksum == 33;
            }
        }, "result");
    }
}
