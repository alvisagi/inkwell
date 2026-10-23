#set page(paper: "a4", margin: 2cm)
#set text(font: "New Computer Modern", size: 11pt)
#set heading(numbering: "1.")

= Introduction
Typst is a *markup-based* typesetting system that is _easy to learn_. 我们的问题是什么？

== Math
The quadratic formula is $x = (-b plus.minus sqrt(b^2 - 4a c)) / (2a)$ and
$ sum_(k=1)^n k = (n(n+1)) / 2 $

== Lists
- First item
- Second item with #text(fill: gradient.linear(red, blue))[a gradient]
+ Numbered

#rect(width: 100%, height: 2cm, fill: gradient.linear(..color.map.viridis), radius: 6pt)

#figure(
  table(columns: 3, [A], [B], [C], [1], [2], [3]),
  caption: [A table],
)

#lorem(80)

