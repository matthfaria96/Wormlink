import AppKit
import SwiftUI

/// Os dois lados num NSSplitView: no modo de um painel o outro lado é recolhido (não removido), então a largura
/// de cada um volta igual ao mostrar os dois de novo, e a posição do divisor fica salva entre aberturas do app.
struct PaneSplitView<Left: View, Right: View>: NSViewControllerRepresentable {
    enum Hidden { case none, left, right }

    var hidden: Hidden
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        for view in [AnyView(left), AnyView(right)] {
            let host = NSHostingController(rootView: AnyView(view.environment(\.self, context.environment)))
            host.sizingOptions = []
            let item = NSSplitViewItem(viewController: host)
            item.minimumThickness = 260
            item.canCollapse = true
            controller.addSplitViewItem(item)
        }
        controller.splitView.autosaveName = "WormlinkPanes"
        apply(hidden, to: controller, animated: false)
        return controller
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        let views = [AnyView(left), AnyView(right)]
        for (item, view) in zip(controller.splitViewItems, views) {
            (item.viewController as? NSHostingController<AnyView>)?.rootView = AnyView(view.environment(\.self, context.environment))
        }
        apply(hidden, to: controller, animated: true)
    }

    private func apply(_ hidden: Hidden, to controller: NSSplitViewController, animated: Bool) {
        let items = controller.splitViewItems
        guard items.count == 2 else { return }
        let wanted = [hidden == .left, hidden == .right]
        for (item, collapse) in zip(items, wanted) where item.isCollapsed != collapse {
            if animated { item.animator().isCollapsed = collapse } else { item.isCollapsed = collapse }
        }
    }
}
