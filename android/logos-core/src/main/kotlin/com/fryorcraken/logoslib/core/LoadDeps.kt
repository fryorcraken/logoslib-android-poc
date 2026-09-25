package com.fryorcraken.logoslib.core

/**
 * How far `logos_core_load_module` walks the dependency graph. Mirrors the C enum
 * `LogosLoadDeps` in logos_core.h (liblogos db45024); [native] is its value.
 */
public enum class LoadDeps(internal val native: Int) {
    /** Load this module alone; its dependencies must already be up. */
    MODULE_ONLY(0),

    /** Load the REQUIRED dependency tree first, in topological order. */
    REQUIRED(1),

    /** As [REQUIRED], plus every installed optional dependency (best effort). */
    REQUIRED_AND_OPTIONAL(2),
}
