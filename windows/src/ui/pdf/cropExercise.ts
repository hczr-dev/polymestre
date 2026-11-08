import type { Exercise } from "../../models/exercise.ts";
import type { CropExercise } from "../../services/pdfExerciseCrop.ts";

/** Ce que la recherche dans le PDF retient d'un exercice. */
export function cropExercise(exercise: Exercise): CropExercise {
  return {
    exerciseNumber: exercise.exerciseNumber,
    title: exercise.title,
    displayNumber: exercise.displayNumber,
    seriesNumber: exercise.series?.seriesNumber ?? null,
    rank: exercise.series ? exercise.series.sortedExercises.findIndex((e) => e.id === exercise.id) : null,
  };
}
