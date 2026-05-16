package org.jetbrains.plugins.template

import com.intellij.testFramework.TestDataPath
import com.intellij.testFramework.fixtures.BasePlatformTestCase

@TestDataPath("\$CONTENT_ROOT/src/test/testData")
class JustfileSmokeTest : BasePlatformTestCase() {

    fun testJustfileLoadsAndHasContent() {
        val psiFile = myFixture.configureByFile("justfile")
        assertNotNull(psiFile)
        assertTrue("justfile should not be empty", psiFile.textLength > 0)
    }

    override fun getTestDataPath() = "src/test/testData"

}
