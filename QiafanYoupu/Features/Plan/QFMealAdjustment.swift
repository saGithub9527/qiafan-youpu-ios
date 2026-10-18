import Foundation

extension QFPlannedMeal {
  var editDraft: QFPlannedMealDraft {
    QFPlannedMealDraft(recipeId: recipeId, date: date, meal: meal, servings: servings,
      expectedRevision: revision, householdId: householdId, skipped: skipped)
  }

  func matches(_ draft: QFPlannedMealDraft) -> Bool {
    recipeId == draft.recipeId && date == draft.date && meal == draft.meal
      && servings == draft.servings && householdId == draft.householdId
      && (draft.skipped == nil || skipped == draft.skipped)
  }
}

extension QFAppSession {
  /// A lost response may have committed. Reconcile a revision conflict using the
  /// latest authenticated read; never retry with a newer revision automatically.
  func adjustPlannedMeal(_ id: String, draft: QFPlannedMealDraft) async throws -> QFPlannedMeal {
    do { return try await savePlannedMeal(id, draft: draft) }
    catch let error as QFAPIError where error.code == 40900 {
      let latest: QFPlannedMeal = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await plannedMeal(id)
      }
      guard latest.matches(draft) else { throw error }
      return latest
    }
  }
}
