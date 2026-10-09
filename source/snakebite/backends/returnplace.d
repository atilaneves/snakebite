module snakebite.backends.returnplace;


private:


public struct ReturnPlace {
    public size_t offset = size_t.max;
    public size_t size;
    public uint alignment = 1;

    public void* bind(
        imported!"snakebite.framestack".FrameStack* frames,
        void* frame,
        void* place,
    ) const @system {
        if (offset == size_t.max)
            return place;
        // A discarded MEMORY-class result still has caller-owned storage.
        if (place is null)
            place = frames.reserve(size, alignment);
        *cast(void**)(cast(ubyte*) frame + offset) = place;
        return place;
    }
}
