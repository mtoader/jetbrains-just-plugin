package org.mvnsearch.plugins.just.lang.injector

import com.intellij.lang.Language
import com.intellij.lang.injection.MultiHostInjector
import com.intellij.lang.injection.MultiHostRegistrar
import com.intellij.openapi.util.TextRange
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiLanguageInjectionHost
import com.intellij.psi.util.parentOfType
import org.mvnsearch.plugins.just.INDENT_CHARS
import org.mvnsearch.plugins.just.PARAM_PREFIX_LIST
import org.mvnsearch.plugins.just.lang.psi.JustCodeBlock
import org.mvnsearch.plugins.just.lang.psi.JustFile
import org.mvnsearch.plugins.just.lang.psi.JustRecipeStatement


class JustCodeBlockLanguageInjector : MultiHostInjector {
    private var shellLanguage: Language? = null
    private var sqlLanguage: Language? = null
    private var tsLanguage: Language? = null

    init {
        sqlLanguage = Language.findLanguageByID("SQL")
        shellLanguage = Language.findLanguageByID("Shell Script")
        tsLanguage = Language.findLanguageByID("TypeScript")
        if (shellLanguage == null) {
            shellLanguage = Language.findLanguageByID("BashPro Shell Script")
        }
    }

    /**
     * Represents a fragment in the code block - either shell code or a Just interpolation ({{...}})
     */
    private data class CodeFragment(
        val range: TextRange,
        val isInterpolation: Boolean
    )

    /**
     * Finds all {{...}} interpolation fragments in the text and returns a list of fragments
     * representing both the shell code segments and interpolation segments.
     * If there are no interpolations, returns a single fragment covering the entire range.
     */
    private fun findCodeFragments(text: String, startOffset: Int, endOffset: Int): List<CodeFragment> {
        val fragments = mutableListOf<CodeFragment>()
        var currentPos = startOffset
        var searchPos = startOffset

        while (searchPos < endOffset) {
            val openBracePos = text.indexOf("{{", searchPos)
            if (openBracePos == -1 || openBracePos >= endOffset) {
                // No more interpolations, add the remaining text as shell code
                if (currentPos < endOffset) {
                    fragments.add(CodeFragment(TextRange(currentPos, endOffset), isInterpolation = false))
                }
                break
            }

            // Find the matching closing braces
            val closeBracePos = text.indexOf("}}", openBracePos + 2)
            if (closeBracePos == -1 || closeBracePos >= endOffset) {
                // Unclosed interpolation, treat rest as shell code
                if (currentPos < endOffset) {
                    fragments.add(CodeFragment(TextRange(currentPos, endOffset), isInterpolation = false))
                }
                break
            }

            // Add shell code before the interpolation (if any)
            if (openBracePos > currentPos) {
                fragments.add(CodeFragment(TextRange(currentPos, openBracePos), isInterpolation = false))
            }

            // Add the interpolation fragment (including the {{ and }})
            val interpolationEnd = closeBracePos + 2
            fragments.add(CodeFragment(TextRange(openBracePos, interpolationEnd), isInterpolation = true))

            currentPos = interpolationEnd
            searchPos = interpolationEnd
        }

        return fragments
    }


    override fun getLanguagesToInject(registrar: MultiHostRegistrar, context: PsiElement) {
        val justFile = context.containingFile as JustFile
        val text = context.text
        val trimmedText = text.trim()
        if (shellLanguage != null && justFile.isBashAlike() && isShellCode(trimmedText)) {
            var injectionScript = justFile.getExportedVariables().joinToString(separator = "") { "$it=''\n" }
            val recipeStatement = context.parentOfType<JustRecipeStatement>()
            if (recipeStatement != null) {
                recipeStatement.params?.recipeParamList?.forEach {
                    it.recipeParamName.text?.let { name ->
                        if (name.startsWith("$")) {
                            val shellVariableName = name.substring(1)
                            injectionScript += "$shellVariableName=''\n"
                        }
                    }
                }
            }
            val offset = text.indexOfFirst { !INDENT_CHARS.contains(it) && !PARAM_PREFIX_LIST.contains(it) }
            if (offset > 0) {
                var trailLength = text.toCharArray().reversedArray().indexOfFirst { !INDENT_CHARS.contains(it) }
                if (trailLength < 0) {
                    trailLength = 0
                }
                val endOffset = context.textLength - trailLength
                if (endOffset > offset) {
                    // Find code fragments, splitting on {{...}} interpolations
                    val fragments = findCodeFragments(text, offset, endOffset)
                    val shellFragments = fragments.filter { !it.isInterpolation && it.range.length > 0 }

                    // Inject Shell language in the non-interpolation fragments
                    if (shellFragments.isNotEmpty()) {
                        registrar.startInjecting(shellLanguage!!)
                        var isFirst = true
                        for (fragment in shellFragments) {
                            val prefix = if (isFirst) injectionScript else null
                            registrar.addPlace(
                                prefix,
                                null,
                                context as PsiLanguageInjectionHost,
                                fragment.range
                            )
                            isFirst = false
                        }
                        registrar.doneInjecting()
                    }
                }
            }
        } else if (sqlLanguage != null && (justFile.isSQLAlike() || isSQLCode(trimmedText))) {
            var textLength = context.textLength
            if (text.endsWith("\n")) {
                textLength -= (textLength - (text.trimEnd().length))
            }
            val offset = text.indexOfFirst { !INDENT_CHARS.contains(it) }
            if (offset > 0) {
                val injectionTextRange = TextRange(offset, textLength)
                registrar.startInjecting(sqlLanguage!!)
                registrar.addPlace(
                    null,
                    null,
                    context as PsiLanguageInjectionHost,
                    injectionTextRange
                )
                registrar.doneInjecting()
            }
        } else if (tsLanguage != null) {
            val firstLine = trimmedText.substringBefore('\n')
            if (firstLine.startsWith("#!") && firstLine.contains("bun")) {
                val offset = text.indexOfFirst { !INDENT_CHARS.contains(it) }
                if (offset > 0) {
                    val injectionTextRange = TextRange(offset, context.textLength)
                    registrar.startInjecting(tsLanguage!!)
                    registrar.addPlace(
                        null,
                        null,
                        context as PsiLanguageInjectionHost,
                        injectionTextRange
                    )
                    registrar.doneInjecting()
                }
            }
        }
    }

    override fun elementsToInjectIn(): MutableList<out Class<out PsiElement>> {
        return mutableListOf(JustCodeBlock::class.java)
    }

    private fun isShellCode(trimmedCode: String): Boolean {
        val firstWord = trimmedCode.substringBefore(' ').lowercase()
        if (firstWord in arrayOf("select", "update", "delete", "insert")) { //SQL style
            return false
        }
        // Note: We no longer bail out when {{}} is present. Instead, we use multihost injection
        // to handle interpolation fragments properly while still providing Shell language support.
        // check shell shebang
        return !trimmedCode.startsWith("#!")
                || trimmedCode.startsWith("#!/usr/bin/env sh")
                || trimmedCode.startsWith("#!/usr/bin/env bash")
                || trimmedCode.startsWith("#!/usr/bin/env zsh")
                || trimmedCode.startsWith("#!/usr/bin/env fish")
    }

    private fun isSQLCode(trimmedCode: String): Boolean {
        val firstWord = trimmedCode.substringBefore(' ').lowercase()
        return firstWord in arrayOf("select", "update", "delete", "insert") //SQL style
    }

}