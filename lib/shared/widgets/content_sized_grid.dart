import 'package:flutter/material.dart';

class ContentSizedGrid extends StatelessWidget {
  const ContentSizedGrid({
    super.key,
    required this.children,
    this.crossAxisCount = 2,
    this.padding = EdgeInsets.zero,
    this.spacing = 12,
  });

  final List<Widget> children;
  final int crossAxisCount;
  final EdgeInsetsGeometry padding;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < children.length; start += crossAxisCount) {
      final rowChildren = <Widget>[];
      for (var column = 0; column < crossAxisCount; column++) {
        if (column > 0) rowChildren.add(SizedBox(width: spacing));
        final childIndex = start + column;
        rowChildren.add(
          Expanded(
            child: childIndex < children.length
                ? children[childIndex]
                : const SizedBox.shrink(),
          ),
        );
      }
      rows.add(
        Padding(
          padding: EdgeInsets.only(
            bottom: start + crossAxisCount < children.length ? spacing : 0,
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rowChildren,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: padding,
      child: Column(children: rows),
    );
  }
}
