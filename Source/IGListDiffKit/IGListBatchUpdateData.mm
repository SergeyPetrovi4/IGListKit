/*
 * Copyright (c) Meta Platforms, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "IGListBatchUpdateData.h"

#import <unordered_map>

#if !__has_include(<IGListDiffKit/IGListDiffKit.h>)
#import "IGListAssert.h"
#else
#import <IGListDiffKit/IGListAssert.h>
#endif

#import "IGListCompatibility.h"

// Plucks the given move from available moves and turns it into a delete + insert
static void convertMoveToDeleteAndInsert(NSMutableSet<IGListMoveIndex *> *moves,
                                         IGListMoveIndex *move,
                                         NSMutableIndexSet *deletes,
                                         NSMutableIndexSet *inserts) {
    [moves removeObject:move];

    // add a delete and insert respecting the move's from and to sections
    // delete + insert will result in reloading the entire section
    [deletes addIndex:move.from];
    [inserts addIndex:move.to];
}

@implementation IGListBatchUpdateData

// Converts all section moves that have index path operations into a section delete + insert.
+ (void)_cleanIndexPathsWithMap:(const std::unordered_map<NSInteger, IGListMoveIndex*> &)map
                         moves:(NSMutableSet<IGListMoveIndex *> *)moves
                    indexPaths:(NSMutableArray<NSIndexPath *> *)indexPaths
                       deletes:(NSMutableIndexSet *)deletes
                       inserts:(NSMutableIndexSet *)inserts {
    for (NSInteger i = indexPaths.count - 1; i >= 0; i--) {
        NSIndexPath *path = indexPaths[i];
        const auto it = map.find(path.section);
        if (it != map.end() && it->second != nil) {
            [indexPaths removeObjectAtIndex:i];
            convertMoveToDeleteAndInsert(moves, it->second, deletes, inserts);
        }
    }
}

/**
 Converts all section moves that are also reloaded, or have index path inserts, deletes, or reloads into a section
 delete + insert in order to avoid UICollectionView heap corruptions, exceptions, and animation/snapshot bugs.
 */
- (instancetype)initWithInsertSections:(nonnull NSIndexSet *)insertSections
                        deleteSections:(nonnull NSIndexSet *)deleteSections
                          moveSections:(nonnull NSSet<IGListMoveIndex *> *)moveSections
                      insertIndexPaths:(nonnull NSArray<NSIndexPath *> *)insertIndexPaths
                      deleteIndexPaths:(nonnull NSArray<NSIndexPath *> *)deleteIndexPaths
                      updateIndexPaths:(nonnull NSArray<NSIndexPath *> *)updateIndexPaths
                        moveIndexPaths:(nonnull NSArray<IGListMoveIndexPath *> *)moveIndexPaths {
    IGParameterAssert(insertSections != nil);
    IGParameterAssert(deleteSections != nil);
    IGParameterAssert(moveSections != nil);
    IGParameterAssert(insertIndexPaths != nil);
    IGParameterAssert(deleteIndexPaths != nil);
    IGParameterAssert(updateIndexPaths != nil);
    IGParameterAssert(moveIndexPaths != nil);
    if (self = [super init]) {
        NSMutableSet<IGListMoveIndex *> *mMoveSections = [moveSections mutableCopy];
        NSMutableIndexSet *mDeleteSections = [deleteSections mutableCopy];
        NSMutableIndexSet *mInsertSections = [insertSections mutableCopy];
        NSMutableSet<IGListMoveIndexPath *> *mMoveIndexPaths = [moveIndexPaths mutableCopy];

        // these collections should NEVER be mutated during cleanup passes, otherwise sections that have multiple item
        // changes (e.g. a moved section that has a delete + reload on different index paths w/in the section) will only
        // convert one of the item changes into a section delete+insert. this will fail hard and be VERY difficult to
        // debug
        const NSInteger moveCount = [moveSections count];
        std::unordered_map<NSInteger, IGListMoveIndex*> fromMap(moveCount);
        std::unordered_map<NSInteger, IGListMoveIndex*> toMap(moveCount);
        for (IGListMoveIndex *move in moveSections) {
            const NSInteger from = move.from;
            const NSInteger to = move.to;

            // if the move is already deleted or inserted, discard it because count-changing operations must match
            // with data source changes
            if ([deleteSections containsIndex:from] || [insertSections containsIndex:to]) {
                [mMoveSections removeObject:move];
            } else {
                fromMap[from] = move;
                toMap[to] = move;
            }
        }

        // avoid a flaky UICollectionView bug when deleting from the same index path twice
        // exposes a possible data source inconsistency issue
        NSMutableArray<NSIndexPath *> *mDeleteIndexPaths = [[[NSSet setWithArray:deleteIndexPaths] allObjects] mutableCopy];
        NSMutableArray<NSIndexPath *> *mInsertIndexPaths = [insertIndexPaths mutableCopy];

        // avoids a bug where a cell is animated twice and one of the snapshot cells is never removed from the hierarchy
        [IGListBatchUpdateData _cleanIndexPathsWithMap:fromMap moves:mMoveSections indexPaths:mDeleteIndexPaths deletes:mDeleteSections inserts:mInsertSections];

        // prevents a bug where UICollectionView corrupts the heap memory when inserting into a section that is moved
        [IGListBatchUpdateData _cleanIndexPathsWithMap:toMap moves:mMoveSections indexPaths:mInsertIndexPaths deletes:mDeleteSections inserts:mInsertSections];

        for (IGListMoveIndexPath *move in moveIndexPaths) {
            // if the section w/ an index path move is deleted, just drop the move
            if ([deleteSections containsIndex:move.from.section]) {
                [mMoveIndexPaths removeObject:move];
            }

            // if a move is inside a section that is moved, convert the section move to a delete+insert
            const auto it = fromMap.find(move.from.section);
            if (it != fromMap.end() && it->second != nil) {
                IGListMoveIndex *sectionMove = it->second;
                [mMoveIndexPaths removeObject:move];
                [mMoveSections removeObject:sectionMove];
                [mDeleteSections addIndex:sectionMove.from];
                [mInsertSections addIndex:sectionMove.to];
            }
        }

        _deleteSections = [mDeleteSections copy];
        _insertSections = [mInsertSections copy];
        _moveSections = [mMoveSections copy];
        _deleteIndexPaths = [mDeleteIndexPaths copy];
        _insertIndexPaths = [mInsertIndexPaths copy];
        _updateIndexPaths = [updateIndexPaths copy];
        _moveIndexPaths = [mMoveIndexPaths copy];
    }
    return self;
}

- (BOOL)isEqual:(id)object {
    if (object == self) {
        return YES;
    }
    if ([object isKindOfClass:[IGListBatchUpdateData class]]) {
        return ([self.insertSections isEqual:[object insertSections]]
                && [self.deleteSections isEqual:[object deleteSections]]
                && [self.moveSections isEqual:[object moveSections]]
                && [self.insertIndexPaths isEqual:[object insertIndexPaths]]
                && [self.deleteIndexPaths isEqual:[object deleteIndexPaths]]
                && [self.updateIndexPaths isEqual:[object updateIndexPaths]]
                && [self.moveIndexPaths isEqual:[object moveIndexPaths]]);
    }
    return NO;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %p; deleteSections: %lu; insertSections: %lu; moveSections: %lu; deleteIndexPaths: %lu; insertIndexPaths: %lu; updateIndexPaths: %lu>",
            NSStringFromClass(self.class), self, (unsigned long)self.deleteSections.count, (unsigned long)self.insertSections.count, (unsigned long)self.moveSections.count,
            (unsigned long)self.deleteIndexPaths.count, (unsigned long)self.insertIndexPaths.count, (unsigned long)self.updateIndexPaths.count];
}

@end
