module ut.backends.run.tryjumps;


// A jump statement inside a `try` statement: in the body, in a handler, or
// in a `finally` body, as the last statement and inside `if`/`else` and a
// `case`. Every test records the order in which the statements ran. A jump
// out of a `try` body or a handler runs each enclosing `finally` body on the
// way out. D does not let a jump leave a `finally` body, so a jump there
// stays inside it, and the `finally` body runs both when the body falls
// through and when it throws.


import ut.backends;


// --- the body of a `try` that has a `catch` and a `finally` ---------------

static foreach (backend; Matrix!()) {
    @("tryJumps.body.returnLast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                try {
                    try {
                        order = order * 10 + 1;
                        return 5;
                    } catch (Exception) order = order * 10 + 8;
                } finally order = order * 10 + 2;
                return 0;
            }

            void main() {
                int order;
                assert(run(order) == 5);
                assert(order == 12);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.body.returnInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int k, ref int order) {
                try {
                    try {
                        if (k == 0)
                            return 5;
                        else
                            order = order * 10 + 3;
                    } catch (Exception) order = order * 10 + 8;
                } finally order = order * 10 + 2;
                return 6;
            }

            void main() {
                int order;
                assert(run(0, order) == 5);
                assert(order == 2);
                order = 0;
                assert(run(1, order) == 6);
                assert(order == 32);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.body.returnInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int k, ref int order) {
                try {
                    try {
                        switch (k) {
                            case 0:
                                return 5;
                            default:
                                order = order * 10 + 3;
                                break;
                        }
                    } catch (Exception) order = order * 10 + 8;
                } finally order = order * 10 + 2;
                return 6;
            }

            void main() {
                int order;
                assert(run(0, order) == 5);
                assert(order == 2);
                order = 0;
                assert(run(1, order) == 6);
                assert(order == 32);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.body.breakLast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 3; ++i) {
                    try {
                        try {
                            order = order * 10 + 1;
                            break;
                        } catch (Exception) order = order * 10 + 8;
                    } finally order = order * 10 + 2;
                    order = order * 10 + 9;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 0);
                assert(order == 12);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.body.breakInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 3; ++i) {
                    try {
                        try {
                            if (i == 1)
                                break;
                            else
                                order = order * 10 + 3;
                        } catch (Exception) order = order * 10 + 8;
                    } finally order = order * 10 + 2;
                    order = order * 10 + 9;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 1);
                assert(order == 3292);
            }
        });
    }
}

// A `break` in a `case` ends the `switch`, not the loop around the `try`.
static foreach (backend; Matrix!()) {
    @("tryJumps.body.breakInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 2; ++i) {
                    try {
                        try {
                            switch (i) {
                                case 0:
                                    break;
                                default:
                                    order = order * 10 + 3;
                                    break;
                            }
                            order = order * 10 + 4;
                        } catch (Exception) order = order * 10 + 8;
                    } finally order = order * 10 + 2;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 2);
                assert(order == 42342);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.body.continueLast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 2; ++i) {
                    try {
                        try {
                            order = order * 10 + 1;
                            continue;
                        } catch (Exception) order = order * 10 + 8;
                    } finally order = order * 10 + 2;
                    order = order * 10 + 9;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 2);
                assert(order == 1212);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.body.continueInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 2; ++i) {
                    try {
                        try {
                            if (i == 0)
                                continue;
                            else
                                order = order * 10 + 3;
                        } catch (Exception) order = order * 10 + 8;
                    } finally order = order * 10 + 2;
                    order = order * 10 + 9;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 2);
                assert(order == 2329);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.body.continueInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 2; ++i) {
                    try {
                        try {
                            switch (i) {
                                case 0:
                                    continue;
                                default:
                                    order = order * 10 + 3;
                                    break;
                            }
                        } catch (Exception) order = order * 10 + 8;
                    } finally order = order * 10 + 2;
                    order = order * 10 + 9;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 2);
                assert(order == 2329);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.body.gotoLast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                try {
                    try {
                        order = order * 10 + 1;
                        goto done;
                    } catch (Exception) order = order * 10 + 8;
                } finally order = order * 10 + 2;
                order = order * 10 + 9;
            done:
                return order;
            }

            void main() {
                int order;
                assert(run(order) == 12);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.body.gotoInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int k, ref int order) {
                try {
                    try {
                        if (k == 0)
                            goto done;
                        else
                            order = order * 10 + 3;
                    } catch (Exception) order = order * 10 + 8;
                } finally order = order * 10 + 2;
                order = order * 10 + 9;
            done:
                return order;
            }

            void main() {
                int order;
                assert(run(0, order) == 2);
                order = 0;
                assert(run(1, order) == 329);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.body.gotoInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int k, ref int order) {
                try {
                    try {
                        switch (k) {
                            case 0:
                                goto done;
                            default:
                                order = order * 10 + 3;
                                break;
                        }
                    } catch (Exception) order = order * 10 + 8;
                } finally order = order * 10 + 2;
                order = order * 10 + 9;
            done:
                return order;
            }

            void main() {
                int order;
                assert(run(0, order) == 2);
                order = 0;
                assert(run(1, order) == 329);
            }
        });
    }
}


// --- a `catch` handler inside a `try` that has a `finally` ----------------

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.returnLast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                try {
                    try throw new Exception("caught");
                    catch (Exception) {
                        order = order * 10 + 1;
                        return 5;
                    }
                } finally order = order * 10 + 2;
                return 0;
            }

            void main() {
                int order;
                assert(run(order) == 5);
                assert(order == 12);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.returnInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int k, ref int order) {
                try {
                    try throw new Exception("caught");
                    catch (Exception) {
                        if (k == 0)
                            return 5;
                        else
                            order = order * 10 + 3;
                    }
                } finally order = order * 10 + 2;
                return 6;
            }

            void main() {
                int order;
                assert(run(0, order) == 5);
                assert(order == 2);
                order = 0;
                assert(run(1, order) == 6);
                assert(order == 32);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.returnInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int k, ref int order) {
                try {
                    try throw new Exception("caught");
                    catch (Exception) {
                        switch (k) {
                            case 0:
                                return 5;
                            default:
                                order = order * 10 + 3;
                                break;
                        }
                    }
                } finally order = order * 10 + 2;
                return 6;
            }

            void main() {
                int order;
                assert(run(0, order) == 5);
                assert(order == 2);
                order = 0;
                assert(run(1, order) == 6);
                assert(order == 32);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.breakLast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 3; ++i) {
                    try {
                        try throw new Exception("caught");
                        catch (Exception) {
                            order = order * 10 + 1;
                            break;
                        }
                    } finally order = order * 10 + 2;
                    order = order * 10 + 9;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 0);
                assert(order == 12);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.breakInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 3; ++i) {
                    try {
                        try throw new Exception("caught");
                        catch (Exception) {
                            if (i == 1)
                                break;
                            else
                                order = order * 10 + 3;
                        }
                    } finally order = order * 10 + 2;
                    order = order * 10 + 9;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 1);
                assert(order == 3292);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.breakInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 2; ++i) {
                    try {
                        try throw new Exception("caught");
                        catch (Exception) {
                            switch (i) {
                                case 0:
                                    break;
                                default:
                                    order = order * 10 + 3;
                                    break;
                            }
                            order = order * 10 + 4;
                        }
                    } finally order = order * 10 + 2;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 2);
                assert(order == 42342);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.continueLast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 2; ++i) {
                    try {
                        try throw new Exception("caught");
                        catch (Exception) {
                            order = order * 10 + 1;
                            continue;
                        }
                    } finally order = order * 10 + 2;
                    order = order * 10 + 9;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 2);
                assert(order == 1212);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.continueInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 2; ++i) {
                    try {
                        try throw new Exception("caught");
                        catch (Exception) {
                            if (i == 0)
                                continue;
                            else
                                order = order * 10 + 3;
                        }
                    } finally order = order * 10 + 2;
                    order = order * 10 + 9;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 2);
                assert(order == 2329);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.continueInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                int i;
                for (; i < 2; ++i) {
                    try {
                        try throw new Exception("caught");
                        catch (Exception) {
                            switch (i) {
                                case 0:
                                    continue;
                                default:
                                    order = order * 10 + 3;
                                    break;
                            }
                        }
                    } finally order = order * 10 + 2;
                    order = order * 10 + 9;
                }
                return i;
            }

            void main() {
                int order;
                assert(run(order) == 2);
                assert(order == 2329);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.gotoLast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                try {
                    try throw new Exception("caught");
                    catch (Exception) {
                        order = order * 10 + 1;
                        goto done;
                    }
                } finally order = order * 10 + 2;
                order = order * 10 + 9;
            done:
                return order;
            }

            void main() {
                int order;
                assert(run(order) == 12);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.gotoInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int k, ref int order) {
                try {
                    try throw new Exception("caught");
                    catch (Exception) {
                        if (k == 0)
                            goto done;
                        else
                            order = order * 10 + 3;
                    }
                } finally order = order * 10 + 2;
                order = order * 10 + 9;
            done:
                return order;
            }

            void main() {
                int order;
                assert(run(0, order) == 2);
                order = 0;
                assert(run(1, order) == 329);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.catch.gotoInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(int k, ref int order) {
                try {
                    try throw new Exception("caught");
                    catch (Exception) {
                        switch (k) {
                            case 0:
                                goto done;
                            default:
                                order = order * 10 + 3;
                                break;
                        }
                    }
                } finally order = order * 10 + 2;
                order = order * 10 + 9;
            done:
                return order;
            }

            void main() {
                int order;
                assert(run(0, order) == 2);
                order = 0;
                assert(run(1, order) == 329);
            }
        });
    }
}


// --- a `finally` body, run after a body that falls through or throws ------

static foreach (backend; Matrix!()) {
    @("tryJumps.finally.breakLast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void run(bool fail, ref int order) {
                try {
                    if (fail)
                        throw new Exception("caught");
                } finally {
                    for (int j; j < 3; ++j) {
                        order = order * 10 + 1;
                        break;
                    }
                    order = order * 10 + 2;
                }
            }

            void main() {
                int order;
                run(false, order);
                assert(order == 12);
                order = 0;
                try run(true, order);
                catch (Exception) order = order * 10 + 5;
                assert(order == 125);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.finally.breakInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void run(bool fail, ref int order) {
                try {
                    if (fail)
                        throw new Exception("caught");
                } finally {
                    for (int j; j < 3; ++j) {
                        if (j == 1)
                            break;
                        else
                            order = order * 10 + 1;
                    }
                    order = order * 10 + 2;
                }
            }

            void main() {
                int order;
                run(false, order);
                assert(order == 12);
                order = 0;
                try run(true, order);
                catch (Exception) order = order * 10 + 5;
                assert(order == 125);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.finally.breakInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void run(bool fail, int k, ref int order) {
                try {
                    if (fail)
                        throw new Exception("caught");
                } finally {
                    switch (k) {
                        case 0:
                            break;
                        default:
                            order = order * 10 + 3;
                            break;
                    }
                    order = order * 10 + 2;
                }
            }

            void main() {
                int order;
                run(false, 0, order);
                assert(order == 2);
                order = 0;
                run(false, 1, order);
                assert(order == 32);
                order = 0;
                try run(true, 1, order);
                catch (Exception) order = order * 10 + 5;
                assert(order == 325);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.finally.continueLast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void run(bool fail, ref int order) {
                try {
                    if (fail)
                        throw new Exception("caught");
                } finally {
                    for (int j; j < 2; ++j) {
                        order = order * 10 + 1;
                        continue;
                    }
                    order = order * 10 + 2;
                }
            }

            void main() {
                int order;
                run(false, order);
                assert(order == 112);
                order = 0;
                try run(true, order);
                catch (Exception) order = order * 10 + 5;
                assert(order == 1125);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.finally.continueInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void run(bool fail, ref int order) {
                try {
                    if (fail)
                        throw new Exception("caught");
                } finally {
                    for (int j; j < 3; ++j) {
                        if (j == 1)
                            continue;
                        else
                            order = order * 10 + 1;
                        order = order * 10 + 4;
                    }
                    order = order * 10 + 2;
                }
            }

            void main() {
                int order;
                run(false, order);
                assert(order == 14142);
                order = 0;
                try run(true, order);
                catch (Exception) order = order * 10 + 5;
                assert(order == 141425);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("tryJumps.finally.continueInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void run(bool fail, ref int order) {
                try {
                    if (fail)
                        throw new Exception("caught");
                } finally {
                    for (int j; j < 3; ++j) {
                        switch (j) {
                            case 1:
                                continue;
                            default:
                                order = order * 10 + 1;
                                break;
                        }
                        order = order * 10 + 4;
                    }
                    order = order * 10 + 2;
                }
            }

            void main() {
                int order;
                run(false, order);
                assert(order == 14142);
                order = 0;
                try run(true, order);
                catch (Exception) order = order * 10 + 5;
                assert(order == 141425);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "DMD CTFE runs the statements that a goto in a finally body skips"),
)) {
    @("tryJumps.finally.gotoInIfElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void run(bool fail, int k, ref int order) {
                try {
                    if (fail)
                        throw new Exception("caught");
                } finally {
                    if (k == 0)
                        goto skip;
                    else
                        order = order * 10 + 3;
                    order = order * 10 + 4;
                skip:
                    order = order * 10 + 2;
                }
            }

            void main() {
                int order;
                run(false, 0, order);
                assert(order == 2);
                order = 0;
                run(false, 1, order);
                assert(order == 342);
                order = 0;
                try run(true, 0, order);
                catch (Exception) order = order * 10 + 5;
                assert(order == 25);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "DMD CTFE runs the statements that a goto in a finally body skips"),
)) {
    @("tryJumps.finally.gotoInCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void run(bool fail, int k, ref int order) {
                try {
                    if (fail)
                        throw new Exception("caught");
                } finally {
                    switch (k) {
                        case 0:
                            goto skip;
                        default:
                            order = order * 10 + 3;
                            break;
                    }
                    order = order * 10 + 4;
                skip:
                    order = order * 10 + 2;
                }
            }

            void main() {
                int order;
                run(false, 0, order);
                assert(order == 2);
                order = 0;
                run(false, 1, order);
                assert(order == 342);
                order = 0;
                try run(true, 0, order);
                catch (Exception) order = order * 10 + 5;
                assert(order == 25);
            }
        });
    }
}


// --- exceptions that meet in a `finally` body -----------------------------

// An exception that a `finally` body throws while another one unwinds is
// chained behind it: the first one reaches the handler, with the second one
// as its `next`.
static foreach (backend; Matrix!()) {
    @("tryJumps.finally.throwChainsBehindPendingException." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void run() {
                try
                    throw new Exception("first");
                finally
                    throw new Exception("second");
            }

            void main() {
                try {
                    run();
                    assert(0);
                } catch (Exception caught) {
                    assert(caught.msg == "first");
                    assert(caught.next !is null);
                    assert(caught.next.msg == "second");
                    assert(caught.next.next is null);
                }
            }
        });
    }
}

// An `Error` that a `finally` body throws while an `Exception` unwinds
// replaces it, and keeps it as the exception it bypassed.
static foreach (backend; Matrix!()) {
    @("tryJumps.finally.errorBypassesPendingException." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int run(ref int order) {
                try {
                    try
                        throw new Exception("first");
                    finally
                        throw new Error("second");
                } catch (Exception) {
                    order = order * 10 + 8;
                }
                return 0;
            }

            void main() {
                int order;
                try {
                    run(order);
                    assert(0);
                } catch (Error caught) {
                    assert(caught.msg == "second");
                    assert(caught.bypassedException !is null);
                    assert(caught.bypassedException.msg == "first");
                }
                assert(order == 0);
            }
        });
    }
}
