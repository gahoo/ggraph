#' @rdname createLayout
#'
#' @export
#'
createLayout.igraph <- function(graph, layout, circular = FALSE, ...) {
    if (inherits(layout, 'function')) {
        layout <- layout(graph, circular = circular, ...)
    } else if (inherits(layout, 'character')) {
        if (is.igraphlayout(layout)) {
            layout <- layout_igraph_igraph(graph, layout, circular, ...)
        } else {
            layoutName <- paste0('layout_igraph_', layout)
            layout <- do.call(layoutName, list(graph, circular = circular, ...))
        }
    } else {
        stop('Unknown layout')
    }
    if (is.null(attr(layout, 'graph'))) {
        attr(layout, 'graph') <- graph
    }
    attr(layout, 'circular') <- circular
    class(layout) <- c(
        'layout_igraph',
        'layout_ggraph',
        'data.frame'
    )
    checkLayout(layout)
}
#' @importFrom igraph as_edgelist V
#'
getEdges.layout_igraph <- function(layout) {
    gr <- attr(layout, 'graph')
    edges <- as.data.frame(as_edgelist(gr, names = FALSE))
    names(edges) <- c('from', 'to')
    eattr <- attr_df(gr, 'edge')
    edges <- cbind(edges, eattr)
    edges$circular <- attr(layout, 'circular')
    edges
}
#' @importFrom igraph shortest_paths
getConnections.layout_igraph <- function(layout, from, to, weight = NULL, mode = 'all') {
    if (is.null(weight)) {
        weight <- NA
    } else {
        weight <- layout[[weight]]
    }
    graph <- attr(layout, 'graph')
    to <- split(to, from)
    connections <- lapply(seq_along(to), function(i) {
        paths <- shortest_paths(graph, as.integer(names(to)[i]), to[[i]], mode = mode, weights = weight)$vpath
        lapply(paths, as.numeric)
    })
    unlist(connections, recursive = FALSE)
}
#' Use igraph layout algorithms for layout_igraph
#'
#' This layout function makes it easy to apply one of the layout algorithms
#' supplied in igraph when plotting with ggraph. Layout names are auto completed
#' so there is no need to write \code{layout_with_graphopt} or
#' \code{layout_as_tree}, just \code{graphopt} and \code{tree} (though the
#' former will also work if you want to be super explicit). Circular layout is
#' only supported for tree-like layout (\code{tree} and \code{sugiyama}) and
#' will throw an error when applied to other layouts.
#'
#' @note This function is not intended to be used directly but by setting
#' \code{layout = 'igraph'} in \code{\link{createLayout}}
#'
#' @param graph An igraph object.
#'
#' @param algorithm The type of layout algorithm to apply. See
#' \code{\link[igraph]{layout_}} for links to the layouts supplied by igraph.
#'
#' @param circular Logical. Should the layout be transformed to a circular
#' representation. Defaults to \code{FALSE}. Only applicable to
#' \code{algorithm = 'tree'} and \code{algorithm = 'sugiyama'}.
#'
#' @param offset If \code{circular = TRUE}, where should it begin. Defaults to
#' \code{pi/2} which is equivalent to 12 o'clock.
#'
#' @param use.dummy Logical. In the case of \code{algorithm = 'sugiyama'} should the
#' dummy-infused graph be used rather than the original. Defaults to
#' \code{FALSE}.
#'
#' @param ... Arguments passed on to the respective layout functions
#'
#' @return A data.frame with the columns \code{x}, \code{y}, \code{circular} as
#' well as any information stored as vertex attributes on the igraph object.
#'
#' @family layout_igraph_*
#'
#' @importFrom igraph layout_as_bipartite layout_as_star layout_as_tree layout_in_circle layout_nicely layout_with_dh layout_with_drl layout_with_gem layout_with_graphopt layout_on_grid layout_with_mds layout_with_sugiyama layout_on_sphere layout_randomly layout_with_fr layout_with_kk layout_with_lgl
#' @importFrom igraph vertex_attr
#'
layout_igraph_igraph <- function(graph, algorithm, circular, offset = pi/2,
                                 use.dummy = FALSE, ...) {
    algorithm <- as.igraphlayout(algorithm)
    layout <- do.call(algorithm, list(graph, ...))
    if (algorithm == 'layout_with_sugiyama') {
        if (use.dummy) {
            layout <- layout$layout.dummy
            graph <- layout$graph
        } else {
            layout <- layout$layout
        }
    }
    extraData <- attr_df(graph)
    layout <- cbind(x=layout[,1], y=layout[,2], extraData)
    if (circular) {
        if (!algorithm %in% c('layout_as_tree', 'layout_with_sugiyama')) {
            stop('Circular layout only applicable to tree and DAG layout')
        }
        radial <- radial_trans(r.range = rev(range(layout$y)),
                               a.range = range(layout$x),
                               offset = offset)
        coords <- radial$transform(layout$y, layout$x)
        layout$x <- coords$x
        layout$y <- coords$y
    }
    layout$circular <- circular
    layout
}
#' Apply a dendrogram layout to layout_igraph
#'
#' This layout mimicks the \code{\link[igraph]{layout_as_tree}} algorithm
#' supplied by igraph, but puts all leaves at 0 and builds it up from there,
#' instead of starting from the root and building it from there. The height of
#' branch points are related to the maximum distance to an edge from the branch
#' node.
#'
#' @note This function is not intended to be used directly but by setting
#' \code{layout = 'dendrogram'} in \code{\link{createLayout}}
#'
#' @param graph An igraph object
#'
#' @param circular Logical. Should the layout be transformed to a circular
#' representation. Defaults to \code{FALSE}.
#'
#' @param offset If \code{circular = TRUE}, where should it begin. Defaults to
#' \code{pi/2} which is equivalent to 12 o'clock.
#'
#' @param direction The direction to the leaves. Defaults to 'out'
#'
#' @return A data.frame with the columns \code{x}, \code{y}, \code{circular} and
#' \code{leaf} as well as any information stored as vertex attributes on the
#' igraph object.
#'
#' @family layout_igraph_*
#'
#' @importFrom igraph gorder degree neighbors
#'
layout_igraph_dendrogram <- function(graph, circular = FALSE, offset = pi/2, direction = 'out') {
    reverseDir <- if (direction == 'out') 'in' else 'out'
    nodes <- data.frame(
        x = rep(NA_real_, gorder(graph)),
        y = rep(NA_real_, gorder(graph)),
        leaf = degree(graph, mode = direction) == 0,
        stringsAsFactors = FALSE
    )
    startnode <- which(degree(graph, mode = reverseDir) == 0)
    if (length(startnode)  < 1) stop('No root nodes in graph')
    recurse_layout <- function(gr, node, layout, direction) {
        children <- as.numeric(neighbors(gr, node, direction))
        if (length(children) == 0) {
            x <- if (all(is.na(layout$x[layout$leaf]))) {
                1
            } else {
                max(layout$x[layout$leaf], na.rm = TRUE) + 1
            }
            layout$x[node] <- x
            layout$y[node] <- 0
            layout
        } else {
            childrenMissing <- children[is.na(layout$x[children])]
            for (i in childrenMissing) {
                layout <- recurse_layout(gr, i, layout, direction)
            }
            layout$x[node] <- mean(layout$x[children])
            layout$y[node] <- max(layout$y[children]) + 1
            layout
        }
    }
    for (i in startnode) {
        nodes <- recurse_layout(graph, i, nodes, direction = direction)
    }
    if (circular) {
        radial <- radial_trans(r.range = rev(range(nodes$y)),
                               a.range = range(nodes$x),
                               offset = offset)
        coords <- radial$transform(nodes$y, nodes$x)
        nodes$x <- coords$x
        nodes$y <- coords$y
    }
    extraData <- attr_df(graph)
    nodes <- cbind(nodes, extraData)
    nodes$circular <- circular
    nodes
}
#' Manually specify a layout for layout_igraph
#'
#' This layout function lets you pass the node positions in manually. Each row
#' in the supplied data frame will correspond to a vertex in the igraph object
#' matched by index.
#'
#' @param graph An igraph object
#'
#' @param node.positions A data.frame with the columns \code{x} and \code{y}
#' (additional columns are ignored).
#'
#' @param circular Ignored
#'
#' @return A data.frame with the columns \code{x}, \code{y}, \code{circular} as
#' well as any information stored as vertex attributes on the igraph object.
#'
#' @family layout_igraph_*
#'
#' @importFrom igraph gorder vertex_attr
#'
layout_igraph_manual <- function(graph, node.positions, circular) {
    if (circular) {
        warning('circular argument ignored for manual layout')
    }
    if (!inherits(node.positions, 'data.frame')) {
        stop('node.positions must be supplied as data.frame')
    }
    if (gorder(graph) != nrow(node.positions)) {
        stop('Number of rows in node.position must correspond to number of nodes in graph')
    }
    if (!all(c('x', 'y') %in% names(node.positions))) {
        stop('node.position must contain the columns "x" and "y"')
    }
    layout <- data.frame(x = node.positions$x, y = node.positions$y)
    extraData <- attr_df(graph)
    layout <- cbind(layout, extraData)
    layout$circular <- FALSE
    layout
}
#' Place nodes on a line or circle
#'
#' This layout puts all nodes on a line, possibly sorted by a node attribute. If
#' \code{circular = TRUE} the nodes will be laid out on the unit circle instead.
#' In the case where the \code{sort.by} attribute is numeric, the numeric values
#' will be used as the x-position and it is thus possible to have uneven spacing
#' between the nodes.
#'
#' @param graph An igraph object
#'
#' @param circular Logical. Should the layout be transformed to a circular
#' representation. Defaults to \code{FALSE}.
#'
#' @param sort.by The name of a vertex attribute to sort the nodes by.
#'
#' @param use.numeric Logical. Should a numeric sort.by attribute be used as the
#' actual x-coordinates in the layout. May lead to overlapping nodes. Defaults
#' to FALSE
#'
#' @param offset If \code{circular = TRUE}, where should it begin. Defaults to
#' \code{pi/2} which is equivalent to 12 o'clock.
#'
#' @return A data.frame with the columns \code{x}, \code{y}, \code{circular} as
#' well as any information stored as vertex attributes on the igraph object.
#'
#' @family layout_igraph_*
#'
#' @importFrom igraph vertex_attr_names vertex_attr gorder
#'
layout_igraph_linear <- function(graph, circular, sort.by = NULL, use.numeric = FALSE, offset = pi/2) {
    if (!is.null(sort.by)) {
        if (!sort.by %in% vertex_attr_names(graph)) {
            stop('sort.by must be a vertex attribute of the graph')
        }
        sort.by <- vertex_attr(graph, sort.by)
        if (is.numeric(sort.by) && use.numeric) {
            x <- sort.by
        } else {
            x <- order(order(sort.by))
        }
    } else {
        x <- seq_len(gorder(graph))
    }
    nodes <- data.frame(x = x, y = 0)
    if (circular) {
        radial <- radial_trans(r.range = rev(range(nodes$y)),
                               a.range = range(nodes$x),
                               offset = offset)
        coords <- radial$transform(nodes$y, nodes$x)
        nodes$x <- coords$x
        nodes$y <- coords$y
    }
    extraData <- attr_df(graph)
    nodes <- cbind(nodes, extraData)
    nodes$circular <- circular
    nodes
}
#' Calculate nodes as rectangels subdividing that of their parent
#'
#' A treemap is a space filling hierarchical layout that maps nodes to
#' rectangles. The rectangles of the children of a node is packed into the
#' rectangle of the node so that the size of a rectangle is a function of the
#' size of the children. The size of the leaf nodes can be mapped arbitrarily
#' (defaults to 1). Many different algorithms exists for dividing a rectangle
#' into smaller bits, some optimizing the aspect ratio and some focusing on the
#' ordering of the rectangles. See details for more discussions on this. The
#' treemap layout was first developed by Ben Shneiderman for visualizing disk
#' usage in the early '90 and has seen many improvements since.
#'
#' @details
#' Different approaches to dividing the rectangles in a treemap exists; all with
#' their strengths and weaknesses. Currently only the split algorithm is
#' implemented which strikes a good balance between aspect ratio and order
#' preservation, but other, more well-known, algorithms such as squarify and
#' slice-and-dice will eventually be implemented.
#'
#' \strong{Algorithms}
#'
#' \emph{Split} (default)
#'
#' The Split algorithm was developed by Björn Engdahl in order to address the
#' downsides of both the original slice-and-dice algorithm (poor aspect ratio)
#' and the popular squarify algorithm (no ordering of nodes). It works by
#' finding the best cut in the ordered list of children in terms of making sure
#' that the two rectangles associated with the split will have optimal aspect
#' ratio.
#'
#' @param graph An igraph object
#'
#' @param algorithm The name of the tiling algorithm to use. Defaults to 'split'
#'
#' @param weight An optional vertex attribute to use as weight. Will only affect
#' the weight of leaf nodes as the weight of non-leaf nodes are derived from
#' their children.
#'
#' @param circular Logical. Should the layout be transformed to a circular
#' representation. Defaults to \code{FALSE}.
#'
#' @param sort.by The name of a vertex attribute to sort the nodes by.
#'
#' @param mode The direction of the tree in the graph. \code{'out'} (default)
#' means that parents point towards their children, while \code{'in'} means that
#' children point towards their parent.
#'
#' @param height The height of the bounding rectangle
#'
#' @param width The width of the bounding rectangle
#'
#' @return A data.frame with the columns \code{x}, \code{y}, \code{width},
#' \code{height}, \code{circular} as well as any information stored as vertex
#' attributes on the igraph object.
#'
#' @references
#' Engdahl, B. (2005). \emph{Ordered and unordered treemap algorithms and their
#' applications on handheld devices}. Master's Degree Project.
#'
#' Johnson, B., & Ben Shneiderman. (1991). \emph{Tree maps: A Space-Filling
#' Approach to the Visualization of Hierarchical Information Structures}. IEEE
#' Visualization, 284–291. \url{http://doi.org/10.1109/VISUAL.1991.175815}
#'
#' @family layout_igraph_*
#'
#' @importFrom igraph vertex_attr_names vertex_attr gorder
#'
layout_igraph_treemap <- function(graph, algorithm = 'split', weight = NULL, circular = FALSE, sort.by = NULL, mode = 'out', height = 1, width = 1) {
    graph <- graph_to_tree(graph, mode)
    hierarchy <- tree_to_hierarchy(graph, mode, sort.by, weight)
    layout <- switch(
        algorithm,
        split = splitTreemap(hierarchy$parent, hierarchy$order, hierarchy$weight, width, height),
        stop('Unknown algorithm')
    )
    layout <- data.frame(x = layout[, 1] + layout[, 3]/2,
                         y = layout[, 2] + layout[, 4]/2,
                         width = layout[, 3],
                         height = layout[, 4],
                         circular = FALSE,
                         leaf = degree(graph, mode = mode) == 0)
    extraData <- attr_df(graph)
    layout <- cbind(layout, extraData)
    layout
}
#' @importFrom igraph gorder vertex_attr gsize induced_subgraph add_vertices E ends add_edges delete_edges %--% edge_attr
#' @export
layout_igraph_hive <- function(graph, axis, axis.pos = NULL, sort.by = NULL, divide.by = NULL, divide.order = NULL, normalize = TRUE, center.size = 0.1, divide.size = 0.05, use.numeric = FALSE, offset = pi/2, split.axes = 'none', split.angle = pi/6, circular = FALSE) {
    axes <- split(seq_len(gorder(graph)), vertex_attr(graph, axis))
    if (is.null(axis.pos)) {
        axis.pos <- rep(1, length(axes))
    } else {
        if (length(axis.pos) != length(axes)) {
            warning("Number of axes not matching axis.pos argument. Recycling as needed")
            axis.pos <- rep(axis.pos, length.out = length(axes))
        }
    }
    axis.pos <- -cumsum(axis.pos)
    axis.pos <- c(0, axis.pos[-length(axis.pos)]) / -tail(axis.pos, 1) * 2 * pi + offset
    if (use.numeric) {
        if (is.null(sort.by) || !is.numeric(vertex_attr(graph, sort.by))) {
            stop('sort.by must be a numeric vertex attribute when use.numeric = TRUE')
        }
        numeric.range <- range(vertex_attr(graph, sort.by))
    }
    if (normalize) {
        normalizeTo <- rep(1, length(axes))
    } else {
        normalizeTo <- lengths(axes) / max(lengths(axes))
    }
    node.pos <- Map(function(nodes, axisLength, axis, angle) {
        splitAxis <- switch(
            split.axes,
            all = TRUE,
            loops = gsize(induced_subgraph(graph, nodes)) > 0,
            none = FALSE,
            stop('Unknown split argument. Use "all", "loops" or "none"')
        )
        nodeDiv <- axisLength / length(nodes)
        if (is.null(divide.by)) {
            nodeSplit <- list(`1` = nodes)
        } else {
            if (use.numeric) {
                stop('Cannot divide axis while use.numeric = TRUE')
            }
            nodeSplit <- split(nodes, vertex_attr(graph, divide.by, nodes))
            if (!is.null(divide.order)) {
                if (!all(divide.order %in% names(nodeSplit))) {
                    stop('All ', divide.by, ' levels must be present in divide.order')
                }
                nodeSplit <- nodeSplit[order(match(names(nodeSplit), divide.order))]
            }
        }
        nodePos <- lapply(nodeSplit, function(nodes) {
            if (length(nodes) == 0) return(numeric())
            if (is.null(sort.by)) {
                pos <- match(seq_along(nodes), order(nodes)) - 1
                pos <- pos * nodeDiv
            } else {
                pos <- vertex_attr(graph, sort.by, nodes)
                if (use.numeric) {
                    if (!is.numeric(pos)) {
                        stop('sort.by must contain numeric data when use.numeric = TRUE')
                    }
                    if (normalize) {
                        if (diff(range(pos)) == 0) {
                            pos <- rep(0.5, length.out = length(pos))
                        } else {
                            pos <- (pos - min(pos))/diff(range(pos))
                        }
                    } else {
                        pos <- (pos - numeric.range[1])/diff(numeric.range)
                    }
                } else {
                    pos <- match(seq_along(pos), order(pos)) - 1
                    pos <- pos * nodeDiv
                }
            }
            pos
        })
        nodePos <- Reduce(function(l, r) {
            append(l, list(r + nodeDiv + divide.size + max(l[[length(l)]])))
        }, x = nodePos[-1], init = nodePos[1])
        nodePos <- unlist(nodePos) + center.size
        data.frame(
            node = nodes,
            r = nodePos[match(nodes, unlist(nodeSplit))],
            centerSize = center.size,
            split = splitAxis,
            axis = axis,
            section = rep(names(nodeSplit), lengths(nodeSplit))[match(nodes, unlist(nodeSplit))],
            angle = angle,
            circular = FALSE,
            stringsAsFactors = FALSE
        )
    }, nodes = axes, axisLength = normalizeTo, axis = names(axes), angle = axis.pos)
    for (i in seq_along(node.pos)) {
        if (node.pos[[i]]$split[1]) {
            nNewNodes <- nrow(node.pos[[i]])
            newNodeStart <- gorder(graph) + 1
            extraNodes <- node.pos[[i]]
            extraNodes$node <- seq(newNodeStart, length.out = nNewNodes)
            vattr <- lapply(vertex_attr(graph), `[`, i = node.pos[[i]]$node)
            graph  <- add_vertices(graph, nNewNodes, attr = vattr)

            loopEdges <- E(graph)[node.pos[[i]]$node %--% node.pos[[i]]$node]
            if (length(loopEdges) != 0) {
                loopEdgesEnds <- ends(graph, loopEdges, names = FALSE)
                correctOrderEnds <- node.pos[[i]]$r[match(loopEdgesEnds[,1], node.pos[[i]]$node)] <
                    node.pos[[i]]$r[match(loopEdgesEnds[,2], node.pos[[i]]$node)]
                loopEdgesEnds <- data.frame(
                    from = ifelse(correctOrderEnds, loopEdgesEnds[,1], loopEdgesEnds[,2]),
                    to = ifelse(correctOrderEnds, loopEdgesEnds[,2], loopEdgesEnds[,1])
                )
                loopEdgesEnds$to <- extraNodes$node[match(loopEdgesEnds$to, node.pos[[i]]$node)]
                loopEdgesEnds <- matrix(c(
                    ifelse(correctOrderEnds, loopEdgesEnds$from, loopEdgesEnds$to),
                    ifelse(correctOrderEnds, loopEdgesEnds$to, loopEdgesEnds$from)
                ), nrow = 2, byrow = TRUE)
                eattr <- lapply(edge_attr(graph), `[`, i = as.numeric(loopEdges))
                graph <- add_edges(graph, as.vector(loopEdgesEnds), attr = eattr)
                graph <- delete_edges(graph, as.numeric(loopEdges))
            }

            nodeCorrection <- unlist(lapply(node.pos[-i], function(ax) {
                correct <- if (ax$angle[1] < node.pos[[i]]$angle[1]) {
                    ax$angle[1] - node.pos[[i]]$angle[1] < -pi
                } else {
                    ax$angle[1] - node.pos[[i]]$angle[1] < pi
                }
                if (correct) ax$node
            }))
            if (length(nodeCorrection) != 0) {
                correctEdges <- E(graph)[node.pos[[i]]$node %--% nodeCorrection]
                correctEdgesEnds <- ends(graph, correctEdges, names = FALSE)
                newNodeInd <- correctEdgesEnds %in% node.pos[[i]]$node
                correctEdgesEnds[newNodeInd] <- extraNodes$node[match(correctEdgesEnds[newNodeInd], node.pos[[i]]$node)]
                eattr <- lapply(edge_attr(graph), `[`, i = as.numeric(correctEdges))
                graph <- add_edges(graph, as.vector(t(correctEdgesEnds)), attr = eattr)
                graph <- delete_edges(graph, as.numeric(correctEdges))
            }

            node.pos[[i]]$angle <- node.pos[[i]]$angle - split.angle/2
            extraNodes$angle <- extraNodes$angle + split.angle/2
            node.pos <- append(node.pos, list(extraNodes))
        }
    }
    node.pos <- lapply(node.pos, function(nodes) {
        nodes$x <- nodes$r * cos(nodes$angle)
        nodes$y <- nodes$r * sin(nodes$angle)
        nodes
    })
    node.pos <- do.call(rbind, node.pos)
    node.pos <- node.pos[order(node.pos$node), names(node.pos) != 'node']
    extraData <- attr_df(graph)
    node.pos <- cbind(node.pos, extraData)
    attr(node.pos, 'graph') <- graph
    node.pos
}
is.igraphlayout <- function(type) {
    if (type %in% igraphlayouts) {
        TRUE
    } else if (any(paste0(c('as_', 'in_', 'with_', 'on_'), type) %in% igraphlayouts)) {
        TRUE
    } else {
        FALSE
    }
}
as.igraphlayout <- function(type) {
    if (type %in% igraphlayouts) {
        layout <- type
    } else {
        newType <- paste0(c('as_', 'in_', 'with_', 'on_'), type)
        typeInd <- which(newType %in% igraphlayouts)
        if (length(typeInd) == 0) {
            stop('Cannot find igraph layout')
        }
        layout <- newType[typeInd]
    }
    paste0('layout_', layout)
}
#' @importFrom igraph degree unfold_tree components induced_subgraph vertex_attr vertex_attr<- is.directed simplify
graph_to_tree <- function(graph, mode) {
    if (!is.directed(graph)) {
        stop('Graph must be directed')
    }
    graph <- simplify(graph)
    parentDir <- if (mode == 'out') 'in' else 'out'
    comp <- components(graph, 'weak')
    if (comp$no > 1) {
        message('Multiple components in graph. Choosing the first')
        graph <- induced_subgraph(graph, which(comp$membership == 1))
    }
    nParents <- degree(graph, mode = parentDir)
    if (!any(nParents == 0)) {
        stop('No root in graph. Provide graph with one parentless node')
    }
    if (any(nParents > 1)) {
        message('Multiple parents. Unfolding graph')
        root <- which(degree(graph, mode = parentDir) == 0)
        if (length(root) > 1) {
            message('Multiple roots in graph. Choosing the first')
            root <- root[1]
        }
        tree <- unfold_tree(graph, mode = mode, roots = root)
        vAttr <- lapply(vertex_attr(graph), `[`, i = tree$vertex_index)
        vertex_attr(tree$tree) <- vAttr
        graph <- tree$tree
    }
    graph
}
#' @importFrom igraph gorder as_edgelist delete_vertex_attr is.named
tree_to_hierarchy <- function(graph, mode, sort.by, weight) {
    if (is.named(graph)) graph <- delete_vertex_attr(graph, 'name')
    parentCol <- if (mode == 'out') 1 else 2
    nodeCol <- if (mode == 'out') 2 else 1
    edges <- as_edgelist(graph)
    hierarchy <- data.frame(parent = rep(-1, gorder(graph)))
    hierarchy$parent[edges[, nodeCol]] <- edges[, parentCol] - 1
    if (is.null(sort.by)) {
        hierarchy$order <- seq_len(nrow(hierarchy))
    } else {
        hierarchy$order <- order(vertex_attr(graph, sort.by))
    }
    leaf <- degree(graph, mode = mode) == 0
    if (is.null(weight)) {
        hierarchy$weight <- 0
        hierarchy$weight[leaf] <- 1
    } else {
        weight <- vertex_attr(graph, weight)
        if (!is.numeric(weight)) {
            stop('Weight must be numeric')
        }
        hierarchy$weight <- weight
        if (any(hierarchy$weight[!leaf] != 0)) {
            message('Non-leaf weights ignored')
        }
        if (any(hierarchy$weight[leaf] == 0)) {
            stop('Leafs must have a weight')
        }
        hierarchy$weight[!leaf] <- 0
    }
    hierarchy
}

#' @importFrom igraph vertex_attr edge_attr gorder gsize
attr_df <- function(gr, type = 'vertex') {
    attrList <- switch(
        type,
        vertex = vertex_attr(gr),
        edge = edge_attr(gr),
        stop('type must be either "vertex" or "edge"')
    )
    if (length(attrList) == 0) {
        nrows <- switch(
            type,
            vertex = gorder(gr),
            edge = gsize(gr),
            stop('type must be either "vertex" or "edge"')
        )
        return(data.frame(matrix(nrow = nrows, ncol = 0)))
    }
    attrList <- lapply(attrList, function(attr) {
        if (class(attr) == 'list') {
            I(attr)
        } else {
            attr
        }
    })
    as.data.frame(attrList)
}

igraphlayouts <- c(
    'as_bipartite',
    'as_star',
    'as_tree',
    'in_circle',
    'nicely',
    'with_dh',
    'with_drl',
    'with_gem',
    'with_graphopt',
    'on_grid',
    'with_mds',
    'with_sugiyama',
    'on_sphere',
    'randomly',
    'with_fr',
    'with_kk',
    'with_lgl'
)
