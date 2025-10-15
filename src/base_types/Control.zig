//! A Control is a high-level node type which has at least one child node.
const Control = @This();

children: std.ArrayList(*Node) = .empty,

/// Adds the given node to the list of children
pub fn addChild(control: *Control, alloc: Allocator, node: *Node) !void {
    try control.children.append(alloc, node);
}

/// Removes the child node at the given index, shifting all following elements forward
pub fn removeChild(control: *Control, idx: usize) void {
    if (idx >= control.children.items.len) return;
    _ = control.children.orderedRemove(idx);
}

pub fn numChildren(control: *const Control) usize {
    return control.children.items.len;
}

pub fn getChild(control: *const Control, idx: usize) *Node {
    return control.children.items[idx];
}

pub fn halt(control: *Control) void {
    for (control.children.items) |child| {
        child.halt();
    }
}

/// Free all resources
pub fn deinit(control: *Control, alloc: Allocator) void {
    for (control.children.items) |node| {
        node.deinit(alloc);
    }
    control.children.deinit(alloc);
}

const Node = @import("../Node.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
