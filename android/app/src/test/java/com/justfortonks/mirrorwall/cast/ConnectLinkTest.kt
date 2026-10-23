package com.justfortonks.mirrorwall.cast

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConnectLinkTest {
    /** Exactly what the Mac's ConnectLinkTests produce; the two sides must keep agreeing. */
    @Test
    fun parsesTheMacsLink() {
        val link = ConnectLink.parse("mirrorwall://connect?name=Mirror%20Wall%202%20%C2%B7%20MacBook%20Pro&port=7450&host=192.168.1.20&host=100.101.102.103")
        assertEquals(ConnectLink("Mirror Wall 2 · MacBook Pro", 7450, listOf("192.168.1.20", "100.101.102.103")), link)
    }

    @Test
    fun missingPortMeansSlotOneAndUnknownItemsAreIgnored() {
        val link = ConnectLink.parse(" MIRRORWALL://connect?host=10.0.0.5&future=1 \n")
        assertEquals(ConnectLink("10.0.0.5", 7350, listOf("10.0.0.5")), link)
    }

    @Test
    fun rejectsOtherLinksAndBadPorts() {
        assertNull(ConnectLink.parse(null))
        assertNull(ConnectLink.parse("https://example.com/?host=1.2.3.4"))
        assertNull(ConnectLink.parse("mirrorwall://other?host=1.2.3.4"))
        assertNull(ConnectLink.parse("mirrorwall://connect?name=x&port=7350"))
        assertNull(ConnectLink.parse("mirrorwall://connect?host=1.2.3.4&port=abc"))
        assertNull(ConnectLink.parse("mirrorwall://connect?host=1.2.3.4&port=70000"))
    }

    @Test
    fun duplicateHostsCollapse() {
        val link = ConnectLink.parse("mirrorwall://connect?host=10.0.0.5&host=10.0.0.5&host=10.0.0.6")
        assertEquals(listOf("10.0.0.5", "10.0.0.6"), link?.hosts)
    }
}
