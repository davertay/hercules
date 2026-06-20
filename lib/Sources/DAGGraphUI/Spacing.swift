import CoreGraphics

/// Internal spacing scale for the DAG views. Ported (trimmed to what the node card uses) from the
/// prototype's cross-cutting `Theme.Spacing`; kept module-private here rather than reintroducing a
/// whole `Theme` module, since the DAG views are the only consumer in this repo today.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
}
